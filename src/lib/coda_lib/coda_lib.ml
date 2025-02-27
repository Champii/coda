[%%import
"../../config.mlh"]

open Core_kernel
open Async_kernel
open Coda_base
open Coda_transition
open Pipe_lib
open Strict_pipe
open Signature_lib
open Coda_state
open O1trace
open Otp_lib
module Ledger_transfer = Ledger_transfer.Make (Ledger) (Ledger.Db)
module Config = Config
module Subscriptions = Coda_subscriptions

type processes = {prover: Prover.t; verifier: Verifier.t}

type components =
  { net: Coda_networking.t
  ; transaction_pool: Network_pool.Transaction_pool.t
  ; snark_pool: Network_pool.Snark_pool.t
  ; transition_frontier: Transition_frontier.t option Broadcast_pipe.Reader.t
  ; most_recent_valid_block: External_transition.t Broadcast_pipe.Reader.t }

type pipes =
  { validated_transitions_reader:
      (External_transition.Validated.t, State_hash.t) With_hash.t
      Strict_pipe.Reader.t
  ; proposer_transition_writer:
      (Transition_frontier.Breadcrumb.t, synchronous, unit Deferred.t) Writer.t
  ; external_transitions_writer:
      (External_transition.t Envelope.Incoming.t * Block_time.t) Pipe.Writer.t
  }

type t =
  { config: Config.t
  ; processes: processes
  ; components: components
  ; pipes: pipes
  ; wallets: Secrets.Wallets.t
  ; propose_keypairs:
      (Agent.read_write Agent.flag, Keypair.And_compressed_pk.Set.t) Agent.t
  ; mutable seen_jobs: Work_selector.State.t
  ; subscriptions: Coda_subscriptions.t
  ; sync_status: Sync_status.t Coda_incremental.Status.Observer.t }
[@@deriving fields]

let subscription t = t.subscriptions

let peek_frontier frontier_broadcast_pipe =
  Broadcast_pipe.Reader.peek frontier_broadcast_pipe
  |> Result.of_option
       ~error:
         (Error.of_string
            "Cannot retrieve transition frontier now. Bootstrapping right now.")

let snark_worker_key t = t.config.snark_worker_key

(* Get the most recently set public keys  *)
let propose_public_keys t : Public_key.Compressed.Set.t =
  let public_keys, _ = Agent.get t.propose_keypairs in
  Public_key.Compressed.Set.map public_keys ~f:snd

let replace_propose_keypairs t kps = Agent.update t.propose_keypairs kps

let best_tip_opt t =
  let open Option.Let_syntax in
  let%map frontier =
    Broadcast_pipe.Reader.peek t.components.transition_frontier
  in
  Transition_frontier.best_tip frontier

let transition_frontier t = t.components.transition_frontier

let root_length_opt t =
  let open Option.Let_syntax in
  let%map frontier =
    Broadcast_pipe.Reader.peek t.components.transition_frontier
  in
  Transition_frontier.root_length frontier

let best_staged_ledger_opt t =
  let open Option.Let_syntax in
  let%map tip = best_tip_opt t in
  Transition_frontier.Breadcrumb.staged_ledger tip

let best_protocol_state_opt t =
  let open Option.Let_syntax in
  let%map tip = best_tip_opt t in
  Transition_frontier.Breadcrumb.transition_with_hash tip
  |> With_hash.data |> External_transition.Validated.protocol_state

let best_ledger_opt t =
  let open Option.Let_syntax in
  let%map staged_ledger = best_staged_ledger_opt t in
  Staged_ledger.ledger staged_ledger

let compose_of_option f =
  Fn.compose
    (Option.value_map ~default:`Bootstrapping ~f:(fun x -> `Active x))
    f

let best_tip = compose_of_option best_tip_opt

let root_length = compose_of_option root_length_opt

[%%if
mock_frontend_data]

let create_sync_status_observer ~logger
    ~transition_frontier_and_catchup_signal_incr ~online_status_incr
    ~first_connection_incr ~first_message_incr =
  let variable = Coda_incremental.Status.Var.create `Offline in
  let incr = Coda_incremental.Status.Var.watch variable in
  let rec loop () =
    let%bind () = Async.after (Core.Time.Span.of_sec 5.0) in
    let current_value = Coda_incremental.Status.Var.value variable in
    let new_sync_status =
      List.random_element_exn
        ( match current_value with
        | `Offline ->
            [`Bootstrap; `Synced]
        | `Synced ->
            [`Offline; `Bootstrap]
        | `Bootstrap ->
            [`Offline; `Synced] )
    in
    Coda_incremental.Status.Var.set variable new_sync_status ;
    Coda_incremental.Status.stabilize () ;
    loop ()
  in
  let observer = Coda_incremental.Status.observe incr in
  Coda_incremental.Status.stabilize () ;
  don't_wait_for @@ loop () ;
  observer

[%%else]

let create_sync_status_observer ~logger
    ~transition_frontier_and_catchup_signal_incr ~online_status_incr
    ~first_connection_incr ~first_message_incr =
  let open Coda_incremental.Status in
  let incremental_status =
    map4 online_status_incr transition_frontier_and_catchup_signal_incr
      first_connection_incr first_message_incr
      ~f:(fun online_status active_status first_connection first_message ->
        match online_status with
        | `Offline ->
            if `Empty = first_connection then (
              Logger.info logger ~module_:__MODULE__ ~location:__LOC__
                "Coda daemon is now connecting" ;
              `Connecting )
            else if `Empty = first_message then (
              Logger.info logger ~module_:__MODULE__ ~location:__LOC__
                "Coda daemon is now listening" ;
              `Listening )
            else `Offline
        | `Online -> (
          match active_status with
          | None ->
              Logger.info (Logger.create ()) ~module_:__MODULE__
                ~location:__LOC__ "Coda daemon is now bootstrapping" ;
              `Bootstrap
          | Some (_, catchup_signal) -> (
            match catchup_signal with
            | `Catchup ->
                Logger.info (Logger.create ()) ~module_:__MODULE__
                  ~location:__LOC__ "Coda daemon is now doing ledger catchup" ;
                `Catchup
            | `Normal ->
                Logger.info (Logger.create ()) ~module_:__MODULE__
                  ~location:__LOC__ "Coda daemon is now synced" ;
                `Synced ) ) )
  in
  let observer = observe incremental_status in
  stabilize () ; observer

[%%endif]

let sync_status t = t.sync_status

let visualize_frontier ~filename =
  compose_of_option
  @@ fun t ->
  let open Option.Let_syntax in
  let%map frontier =
    Broadcast_pipe.Reader.peek t.components.transition_frontier
  in
  Transition_frontier.visualize ~filename frontier

let best_staged_ledger = compose_of_option best_staged_ledger_opt

let best_protocol_state = compose_of_option best_protocol_state_opt

let best_ledger = compose_of_option best_ledger_opt

let get_ledger t staged_ledger_hash_opt =
  let open Deferred.Or_error.Let_syntax in
  let%bind staged_ledger_hash =
    Option.value_map staged_ledger_hash_opt ~f:Deferred.Or_error.return
      ~default:
        ( match best_staged_ledger t with
        | `Active staged_ledger ->
            Deferred.Or_error.return (Staged_ledger.hash staged_ledger)
        | `Bootstrapping ->
            Deferred.Or_error.error_string
              "get_ledger: can't get staged ledger hash while bootstrapping" )
  in
  let%bind frontier =
    Deferred.return (t.components.transition_frontier |> peek_frontier)
  in
  match
    List.find_map (Transition_frontier.all_breadcrumbs frontier) ~f:(fun b ->
        let staged_ledger = Transition_frontier.Breadcrumb.staged_ledger b in
        if
          Staged_ledger_hash.equal
            (Staged_ledger.hash staged_ledger)
            staged_ledger_hash
        then Some (Ledger.to_list (Staged_ledger.ledger staged_ledger))
        else None )
  with
  | Some x ->
      Deferred.Or_error.return x
  | None ->
      Deferred.Or_error.error_string
        "get_ledger: staged ledger hash not found in transition frontier"

let seen_jobs t = t.seen_jobs

let add_block_subscriber t public_key =
  Coda_subscriptions.add_block_subscriber t.subscriptions public_key

let add_payment_subscriber t public_key =
  Coda_subscriptions.add_payment_subscriber t.subscriptions public_key

let set_seen_jobs t seen_jobs = t.seen_jobs <- seen_jobs

let transaction_pool t = t.components.transaction_pool

let transaction_database t = t.config.transaction_database

let external_transition_database t = t.config.external_transition_database

let snark_pool t = t.components.snark_pool

let peers t = Coda_networking.peers t.components.net

let initial_peers t = Coda_networking.initial_peers t.components.net

let snark_work_fee t = t.config.snark_work_fee

let receipt_chain_database t = t.config.receipt_chain_database

let top_level_logger t = t.config.logger

let most_recent_valid_transition t = t.components.most_recent_valid_block

let staged_ledger_ledger_proof t =
  let open Option.Let_syntax in
  let%bind sl = best_staged_ledger_opt t in
  Staged_ledger.current_ledger_proof sl

let validated_transitions t = t.pipes.validated_transitions_reader

let root_diff t =
  let root_diff_reader, root_diff_writer =
    Strict_pipe.create ~name:"root diff"
      (Buffered (`Capacity 30, `Overflow Crash))
  in
  don't_wait_for
    (Broadcast_pipe.Reader.iter t.components.transition_frontier ~f:(function
      | None ->
          Deferred.unit
      | Some frontier ->
          Broadcast_pipe.Reader.iter
            (Transition_frontier.root_diff_pipe frontier) ~f:(fun root_diff ->
              Strict_pipe.Writer.write root_diff_writer root_diff
              |> Deferred.return ) )) ;
  root_diff_reader

let dump_tf t =
  peek_frontier t.components.transition_frontier
  |> Or_error.map ~f:Transition_frontier.visualize_to_string

(** The [best_path coda] is the list of state hashes from the root to the best_tip in the transition frontier. It includes the root hash and the hash *)
let best_path t =
  let open Option.Let_syntax in
  let%map tf = Broadcast_pipe.Reader.peek t.components.transition_frontier in
  let bt = Transition_frontier.best_tip tf in
  List.cons
    Transition_frontier.(root tf |> Breadcrumb.state_hash)
    (Transition_frontier.hash_path tf bt)

let request_work t =
  let open Option.Let_syntax in
  let (module Work_selection_method) = t.config.work_selection_method in
  let%bind sl =
    match best_staged_ledger t with
    | `Active staged_ledger ->
        Some staged_ledger
    | `Bootstrapping ->
        Logger.info t.config.logger ~module_:__MODULE__ ~location:__LOC__
          "Snark-work-request error: Could not retrieve staged_ledger due to \
           bootstrapping" ;
        None
  in
  let fee = snark_work_fee t in
  let instances, seen_jobs =
    Work_selection_method.work ~logger:t.config.logger ~fee
      ~snark_pool:(snark_pool t) sl (seen_jobs t)
  in
  set_seen_jobs t seen_jobs ;
  if List.is_empty instances then None
  else Some {Snark_work_lib.Work.Spec.instances; fee}

let start t =
  Proposer.run ~logger:t.config.logger ~verifier:t.processes.verifier
    ~prover:t.processes.prover ~trust_system:t.config.trust_system
    ~transaction_resource_pool:
      (Network_pool.Transaction_pool.resource_pool
         t.components.transaction_pool)
    ~get_completed_work:
      (Network_pool.Snark_pool.get_completed_work t.components.snark_pool)
    ~time_controller:t.config.time_controller
    ~keypairs:(Agent.read_only t.propose_keypairs)
    ~consensus_local_state:t.config.consensus_local_state
    ~frontier_reader:t.components.transition_frontier
    ~transition_writer:t.pipes.proposer_transition_writer

let create_genesis_frontier (config : Config.t) ~verifier =
  let consensus_local_state = config.consensus_local_state in
  let pending_coinbases = Pending_coinbase.create () |> Or_error.ok_exn in
  let empty_diff =
    { Staged_ledger_diff.diff=
        ( { completed_works= []
          ; user_commands= []
          ; coinbase= Staged_ledger_diff.At_most_two.Zero }
        , None )
    ; creator= Account.public_key (snd (List.hd_exn Genesis_ledger.accounts))
    }
  in
  let genesis_protocol_state =
    With_hash.data (Lazy.force Genesis_protocol_state.t)
  in
  (* the genesis transition is assumed to be valid *)
  let (`I_swear_this_is_safe_see_my_comment first_transition) =
    External_transition.Validated.create_unsafe
      (External_transition.create ~protocol_state:genesis_protocol_state
         ~protocol_state_proof:Precomputed_values.base_proof
         ~staged_ledger_diff:empty_diff)
  in
  let genesis_ledger = Lazy.force Genesis_ledger.t in
  let load () =
    let ledger_db =
      Ledger.Db.create ?directory_name:config.ledger_db_location ()
    in
    ( ledger_db
    , Ledger_transfer.transfer_accounts ~src:genesis_ledger ~dest:ledger_db )
  in
  let%bind root_snarked_ledger =
    match load () with
    | _, Ok l ->
        return l
    | ledger_db, Error _ ->
        (* Persisted state was bogus. Give up on the ledger contents, we'll bootstrap. *)
        Ledger.Db.close ledger_db ;
        let%map () =
          match config.ledger_db_location with
          | Some ledger_db_location ->
              Logger.error config.logger
                "Failed to load genesis ledger, deleting $dir and trying again."
                ~module_:__MODULE__ ~location:__LOC__
                ~metadata:[("dir", `String ledger_db_location)] ;
              File_system.remove_dir ledger_db_location
          | None ->
              Deferred.unit
        in
        snd (load ()) |> Or_error.ok_exn
    (* If it fails again, something is very wrong. Die. *)
  in
  let snarked_ledger_hash =
    Frozen_ledger_hash.of_ledger_hash @@ Ledger.merkle_root genesis_ledger
  in
  let%bind root_staged_ledger =
    match%map
      Staged_ledger.of_scan_state_and_ledger ~logger:config.logger ~verifier
        ~snarked_ledger_hash ~ledger:genesis_ledger
        ~scan_state:(Staged_ledger.Scan_state.empty ())
        ~pending_coinbase_collection:pending_coinbases
    with
    | Ok staged_ledger ->
        staged_ledger
    | Error err ->
        Error.raise err
  in
  let%map frontier =
    Transition_frontier.create ~logger:config.logger
      ~root_transition:
        (With_hash.of_data first_transition
           ~hash_data:
             (Fn.compose Protocol_state.hash
                External_transition.Validated.protocol_state))
      ~root_staged_ledger ~root_snarked_ledger ~consensus_local_state
  in
  (root_snarked_ledger, frontier)

let create (config : Config.t) =
  let monitor = Option.value ~default:(Monitor.create ()) config.monitor in
  Async.Scheduler.within' ~monitor (fun () ->
      trace_task "coda" (fun () ->
          let%bind prover = Prover.create () in
          let%bind verifier = Verifier.create () in
          let external_transitions_reader, external_transitions_writer =
            Strict_pipe.create Synchronous
          in
          let proposer_transition_reader, proposer_transition_writer =
            Strict_pipe.create Synchronous
          in
          let net_ivar = Ivar.create () in
          let%bind ledger_db, transition_frontier =
            create_genesis_frontier config ~verifier
          in
          let genesis_transition =
            Transition_frontier.(
              root transition_frontier |> Breadcrumb.external_transition
              |> External_transition.Validated.forget_validation)
          in
          let frontier_broadcast_pipe_r, frontier_broadcast_pipe_w =
            Broadcast_pipe.create None
          in
          let handle_request ~f query_env =
            let input = Envelope.Incoming.data query_env in
            Deferred.return
            @@
            let open Option.Let_syntax in
            let%bind frontier =
              Broadcast_pipe.Reader.peek frontier_broadcast_pipe_r
            in
            f ~frontier input
          in
          let%bind net =
            Coda_networking.create config.net_config
              ~get_staged_ledger_aux_and_pending_coinbases_at_hash:
                (handle_request
                   ~f:
                     Sync_handler
                     .get_staged_ledger_aux_and_pending_coinbases_at_hash)
              ~answer_sync_ledger_query:(fun query_env ->
                let open Deferred.Or_error.Let_syntax in
                let ledger_hash, _ = Envelope.Incoming.data query_env in
                let%bind frontier =
                  Deferred.return @@ peek_frontier frontier_broadcast_pipe_r
                in
                Sync_handler.answer_query ~frontier ledger_hash
                  (Envelope.Incoming.map ~f:Tuple2.get2 query_env)
                  ~logger:config.logger ~trust_system:config.trust_system
                |> Deferred.map
                   (* begin error string prefix so we can pattern-match *)
                     ~f:
                       (Result.of_option
                          ~error:
                            (Error.createf
                               !"%s for ledger_hash: %{sexp:Ledger_hash.t}"
                               Coda_networking.refused_answer_query_string
                               ledger_hash)) )
              ~get_ancestry:
                (handle_request
                   ~f:(Sync_handler.Root.prove ~logger:config.logger))
              ~get_bootstrappable_best_tip:
                (handle_request
                   ~f:
                     (Sync_handler.Bootstrappable_best_tip.prove
                        ~logger:config.logger))
              ~get_transition_chain_witness:
                (handle_request ~f:Transition_chain_witness.prove)
              ~get_transition_chain:
                (handle_request ~f:Sync_handler.get_transition_chain)
          in
          let transaction_pool =
            Network_pool.Transaction_pool.create ~logger:config.logger
              ~trust_system:config.trust_system
              ~incoming_diffs:(Coda_networking.transaction_pool_diffs net)
              ~frontier_broadcast_pipe:frontier_broadcast_pipe_r
          in
          let ((most_recent_valid_block_reader, _) as most_recent_valid_block)
              =
            Broadcast_pipe.create genesis_transition
          in
          let valid_transitions =
            Transition_router.run ~logger:config.logger
              ~trust_system:config.trust_system ~verifier ~network:net
              ~time_controller:config.time_controller
              ~frontier_broadcast_pipe:
                (frontier_broadcast_pipe_r, frontier_broadcast_pipe_w)
              ~ledger_db
              ~network_transition_reader:
                (Strict_pipe.Reader.map external_transitions_reader
                   ~f:(fun (tn, tm) -> (`Transition tn, `Time_received tm)))
              ~proposer_transition_reader transition_frontier
              ~most_recent_valid_block
          in
          let ( valid_transitions_for_network
              , valid_transitions_for_api
              , new_blocks ) =
            Strict_pipe.Reader.Fork.three valid_transitions
          in
          don't_wait_for
            (Linear_pipe.iter
               (Network_pool.Transaction_pool.broadcasts transaction_pool)
               ~f:(fun x ->
                 Coda_networking.broadcast_transaction_pool_diff net x ;
                 Deferred.unit )) ;
          Ivar.fill net_ivar net ;
          don't_wait_for
            (Strict_pipe.Reader.iter_without_pushback
               valid_transitions_for_network ~f:(fun transition_with_hash ->
                 let hash = With_hash.hash transition_with_hash in
                 let consensus_state =
                   With_hash.data transition_with_hash
                   |> External_transition.Validated.protocol_state
                   |> Protocol_state.consensus_state
                 in
                 let now =
                   let open Block_time in
                   now config.time_controller |> to_span_since_epoch
                   |> Span.to_ms
                 in
                 match
                   Consensus.Hooks.received_at_valid_time ~time_received:now
                     consensus_state
                 with
                 | Ok () ->
                     Logger.trace config.logger ~module_:__MODULE__
                       ~location:__LOC__
                       ~metadata:
                         [ ("state_hash", State_hash.to_yojson hash)
                         ; ( "external_transition"
                           , External_transition.Validated.to_yojson
                               (With_hash.data transition_with_hash) ) ]
                       "Rebroadcasting $state_hash" ;
                     (* remove verified status for network broadcast *)
                     Coda_networking.broadcast_state net
                       (External_transition.Validated.forget_validation
                          (With_hash.data transition_with_hash))
                 | Error reason ->
                     let timing_error_json =
                       match reason with
                       | `Too_early ->
                           `String "too early"
                       | `Too_late slots ->
                           `String (sprintf "%Lu slots too late" slots)
                     in
                     Logger.warn config.logger ~module_:__MODULE__
                       ~location:__LOC__
                       ~metadata:
                         [ ("state_hash", State_hash.to_yojson hash)
                         ; ( "external_transition"
                           , External_transition.Validated.to_yojson
                               (With_hash.data transition_with_hash) )
                         ; ("timing", timing_error_json) ]
                       "Not rebroadcasting block $state_hash because it was \
                        received $timing" )) ;
          don't_wait_for
            (Strict_pipe.transfer
               (Coda_networking.states net)
               external_transitions_writer ~f:ident) ;
          don't_wait_for
            (Linear_pipe.iter (Coda_networking.ban_notification_reader net)
               ~f:(fun notification ->
                 let peer = Coda_networking.banned_peer notification in
                 let banned_until =
                   Coda_networking.banned_until notification
                 in
                 (* if RPC call fails, will be logged in gossip net code *)
                 let%map _ =
                   Coda_networking.ban_notify net peer banned_until
                 in
                 () )) ;
          let%bind snark_pool =
            Network_pool.Snark_pool.load ~logger:config.logger
              ~trust_system:config.trust_system
              ~disk_location:config.snark_pool_disk_location
              ~incoming_diffs:(Coda_networking.snark_pool_diffs net)
              ~frontier_broadcast_pipe:frontier_broadcast_pipe_r
          in
          let%bind wallets =
            Secrets.Wallets.load ~logger:config.logger
              ~disk_location:config.wallets_disk_location
          in
          don't_wait_for
            (Linear_pipe.iter (Network_pool.Snark_pool.broadcasts snark_pool)
               ~f:(fun x ->
                 Coda_networking.broadcast_snark_pool_diff net x ;
                 Deferred.unit )) ;
          let propose_keypairs =
            Agent.create
              ~f:(fun kps ->
                Keypair.Set.to_list kps
                |> List.map ~f:(fun kp ->
                       (kp, Public_key.compress kp.Keypair.public_key) )
                |> Keypair.And_compressed_pk.Set.of_list )
              config.initial_propose_keypairs
          in
          let subscriptions =
            Coda_subscriptions.create ~logger:config.logger
              ~time_controller:config.time_controller ~new_blocks ~wallets
              ~external_transition_database:config.external_transition_database
              ~transition_frontier:frontier_broadcast_pipe_r
              ~is_storing_all:config.is_archive_node
          in
          let open Coda_incremental.Status in
          let transition_frontier_incr =
            Var.watch @@ of_broadcast_pipe frontier_broadcast_pipe_r
          in
          let transition_frontier_and_catchup_signal_incr =
            transition_frontier_incr
            >>= function
            | Some transition_frontier ->
                Transition_frontier.catchup_signal transition_frontier
                |> of_broadcast_pipe |> Var.watch
                >>| fun catchup_signal ->
                Some (transition_frontier, catchup_signal)
            | None ->
                return None
          in
          let sync_status =
            create_sync_status_observer ~logger:config.logger
              ~transition_frontier_and_catchup_signal_incr
              ~online_status_incr:
                ( Var.watch @@ of_broadcast_pipe
                @@ Coda_networking.online_status net )
              ~first_connection_incr:
                (Var.watch @@ of_ivar @@ Coda_networking.first_connection net)
              ~first_message_incr:
                (Var.watch @@ of_ivar @@ Coda_networking.first_message net)
          in
          Deferred.return
            { config
            ; processes= {prover; verifier}
            ; components=
                { net
                ; transaction_pool
                ; snark_pool
                ; transition_frontier= frontier_broadcast_pipe_r
                ; most_recent_valid_block= most_recent_valid_block_reader }
            ; pipes=
                { validated_transitions_reader= valid_transitions_for_api
                ; proposer_transition_writer
                ; external_transitions_writer=
                    Strict_pipe.Writer.to_linear_pipe
                      external_transitions_writer }
            ; wallets
            ; propose_keypairs
            ; seen_jobs=
                Work_selector.State.init
                  ~reassignment_wait:config.work_reassignment_wait
            ; subscriptions
            ; sync_status } ) )
