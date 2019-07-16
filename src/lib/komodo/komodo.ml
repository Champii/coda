open Core
open Async
open Coda_base

(* TODO: use coda config system to store this *)
(* let daemon_addr_ = "http://192.168.1.26:8945/" *)
let daemon_addr_ = "http://192.168.43.6:8945/"

let komodo_burn_addr = "RHRkomCUgeYVQtSVoCQXgKjkjrnDvFaeAM"

let credentials =
  `Basic
    ( "user2092408878"
    , "pass47438fa7ad18431ab4a2a2994983db08fcde31c32528fe6264423087e32de2e2fb"
    )

let send_rpc message =
  let open Cohttp in
  let open Cohttp_async in
  let headers = Header.add_authorization (Header.init ()) credentials in
  let data = Yojson.Basic.to_string message in
  Client.post ~headers ~body:(Body.of_string data) (Uri.of_string daemon_addr_)
  >>= fun (_, body) -> body |> Body.to_string

let get_raw_tx id =
  let request =
    `Assoc
      [ ("jsonrpc", `String "1.0")
      ; ("id", `String "tototata") (* TODO: generate a unique id *)
      ; ("method", `String "getrawtransaction")
      ; ("params", `List [`String id; `Int 1]) ]
  in
  send_rpc request

let get_amount_address tx =
  (*TODO: extract that from some future field in tx*)
  let coda_dest_addr =
    "AShMU6Qe0gQxi8Z9ki0IjdyO9cVlkY4zeKtJOKkO+YjfxUfYIi/IAQAAAQ=="
  in
  let open Yojson.Basic.Util in
  let get_addrs_predicate x =
    let addrs =
      x |> member "scriptPubKey" |> member "addresses" |> to_list
      |> filter_string
    in
    let found = List.find ~f:(fun y -> y = komodo_burn_addr) addrs in
    match found with Some _ -> true | _ -> false
  in
  let vout0_option =
    List.find ~f:get_addrs_predicate
      (tx |> member "result" |> member "vout" |> to_list)
  in
  match vout0_option with
  | None ->
      Error
        (Error.of_string
           "Error: Malformed json answer: No vout field in transaction")
  | Some vout0 -> (
      let amount = vout0 |> member "valueSat" |> to_int in
      let address_option =
        List.hd
          ( vout0 |> member "scriptPubKey" |> member "addresses" |> to_list
          |> filter_string )
      in
      match address_option with
      | None ->
          Error
            (Error.of_string
               "Error: Malformed json answer: No vout address in transaction")
      | Some addr_to ->
          Ok (amount, addr_to, coda_dest_addr) )

let validate_burn_addr tx =
  Result.bind (get_amount_address tx)
    ~f:(fun (amount, addr_to, coda_dest_addr) ->
      if addr_to = komodo_burn_addr then Ok (amount, addr_to, coda_dest_addr)
      else
        Error
          (Error.of_string
             "Error: Transaction receiver is not the burn address") )

(* TODO: Check tx depth *)
let validate_tx tx_str =
  let open Yojson.Basic.Util in
  let tx = Yojson.Basic.from_string tx_str in
  let error = tx |> member "error" in
  if error <> `Null then
    Error
      (Error.of_string
         ( "Error: Komodo daemon answered with an error:\n"
         ^ (error |> member "message" |> to_string) ))
  else validate_burn_addr tx

let get_and_validate_tx (txn : Add_fund.t) =
  let tx_str = get_raw_tx txn in
  Deferred.map tx_str ~f:validate_tx
