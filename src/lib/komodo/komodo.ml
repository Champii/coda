open Core
open Async

(* TODO: use coda config system to store this *)
let daemon_addr_ = "http://192.168.1.26:8945/"

let komodo_burn_addr = "RHRkomCUgeYVQtSVoCQXgKjkjrnDvFaeAM"

let get_vout_list rawtx =
  let open Yojson.Basic.Util in
  rawtx |> member "result" |> member "vout" |> to_list

let get_vin_sender_addr rawtx =
  let open Yojson.Basic.Util in
  rawtx |> member "result" |> member "vin" |> to_list |> List.hd_exn
  |> member "address" |> to_string

let get_vout_addr_list vout =
  let open Yojson.Basic.Util in
  vout |> member "scriptPubKey" |> member "addresses" |> to_list
  |> filter_string

let get_vout_amount vout =
  let open Yojson.Basic.Util in
  vout |> member "valueSat" |> to_int

let find_addr_predicate vout =
  let addrs = get_vout_addr_list vout in
  let found = List.find ~f:(fun y -> y = komodo_burn_addr) addrs in
  match found with Some _ -> true | _ -> false

let get_amount_address tx =
  (*TODO: extract that from some future field in tx*)
  let coda_dest_addr =
    "8QnLWmoTWZ9n2RwsiBTsNyGk8DZoSdgXbJmrsdZRZFLDHSyEamzZzNbHGUj4466zUg"
  in
  let _ =
    Signature_lib.Public_key.Compressed.of_base58_check
      "8QnLWmoTWZ9n2RwsiBTsNyGk8DZoSdgXbJmrsdZRZFLDHSyEamzZzNbHGUj4466zUg"
  in
  let vouts = get_vout_list tx in
  let komodo_sender_addr = get_vin_sender_addr tx in
  let vout = List.find ~f:find_addr_predicate vouts in
  match vout with
  | None ->
      Error
        (Error.of_string
           "Error: Malformed json answer: No vout field in transaction")
  | Some vout0 -> (
      let amount = get_vout_amount vout0 in
      let address_option = List.hd (get_vout_addr_list vout0) in
      match address_option with
      | None ->
          Error
            (Error.of_string
               "Error: Malformed json answer: No vout address in transaction")
      | Some addr_to ->
          Ok (amount, addr_to, coda_dest_addr, komodo_sender_addr) )

let validate_burn_addr tx =
  Result.bind (get_amount_address tx)
    ~f:(fun (amount, addr_to, coda_dest_addr, komodo_sender_address) ->
      if addr_to = komodo_burn_addr then
        Ok (amount, coda_dest_addr, komodo_sender_address)
      else
        Error
          (Error.of_string
             "Error: Transaction receiver is not the burn address") )

(* TODO: Check komodo tx depth and coda dest addr validity *)
let validate_tx tx =
  let open Yojson.Basic.Util in
  let error = tx |> member "error" in
  if error <> `Null then
    Error
      (Error.of_string
         ( "Error: Komodo daemon answered with an error:\n"
         ^ (error |> member "message" |> to_string) ))
  else validate_burn_addr tx

let make_curl_call command params =
  let request =
    `Assoc
      [ ("jsonrpc", `String "1.0")
      ; ("id", `String "tototata") (* TODO: generate a unique id *)
      ; ("method", `String command)
      ; ("params", `List params) ]
  in
  let request_str = Yojson.to_string request in
  let cmd =
    "curl -s --user \
     user2092408878:pass47438fa7ad18431ab4a2a2994983db08fcde31c32528fe6264423087e32de2e2fb \
     --data-binary '" ^ request_str
    ^ "' -H 'content-type: text/plain;' http://192.168.1.26:8945/"
  in
  let i, _ = Core.Unix.open_process cmd in
  Pervasives.input_line i

let get_tx_sync (txn : string) =
  let tx_str = make_curl_call "getrawtransaction" [`String txn; `Int 1] in
  Yojson.Basic.from_string tx_str

let get_address_pubkey (addr : string) =
  let res_str = make_curl_call "validateaddress" [`String addr] in
  let res = Yojson.Basic.from_string res_str in
  let open Yojson.Basic.Util in
  let error = res |> member "error" in
  if error <> `Null then Error (Error.of_string "Error")
  else Ok (res |> member "result" |> member "pubkey" |> to_string)

(* Yojson.Basic.from_string res_str *)

let get_and_validate_tx_sync (txn : string) = validate_tx @@ get_tx_sync txn

module Base58_check = Base58_check.Make (struct
  let description = "KOMODO_ADDRESS"

  let version_byte = Base58_check.Version_bytes.komodo_hash
end)

let derive_komodo_verif_payment_addr (receipt : string) txid =
  let first =
    Digestif.SHA256.digest_string (receipt ^ txid)
    |> Digestif.SHA256.to_raw_string
  in
  let second =
    Digestif.RMD160.digest_string first |> Digestif.RMD160.to_raw_string
  in
  let res = Base58_check.encode second in
  let _ = printf "DERIVED: %s\n" res in
  res

let send_validation_payment (receipt : string) (txid : string) =
  let burn_claim_addr = derive_komodo_verif_payment_addr receipt txid in
  let tx_str =
    make_curl_call "sendtoaddress" [`String burn_claim_addr; `Float 0.00001]
  in
  let _ = print_endline @@ "Komodo burn claim txid" ^ tx_str in
  let res = Yojson.Basic.from_string tx_str in
  let open Yojson.Basic.Util in
  let error = res |> member "error" in
  if error = `Null then Ok (res |> member "result") else Error "Error"

let get_address_txids address =
  let txids_str = make_curl_call "getaddresstxids" [`String address] in
  let _ = print_endline @@ "Komodo address_txids" ^ txids_str in
  let txids = Yojson.Basic.from_string txids_str in
  let open Yojson.Basic.Util in
  let error = txids |> member "error" in
  if error = `Null then
    Ok (txids |> member "result" |> to_list |> filter_string)
  else Error "Error"

let validate_marker_exists sender_addr _receipt txid =
  let expected_marker = derive_komodo_verif_payment_addr sender_addr txid in
  let address_txids_opt = get_address_txids expected_marker in
  let sender_pubkey = get_address_pubkey sender_addr |> Or_error.ok_exn in
  match address_txids_opt with
  | Ok address_txids ->
      let txs = List.map address_txids ~f:get_tx_sync in
      let senders = List.map txs ~f:get_vin_sender_addr in
      let pubkeys =
        List.map senders ~f:(fun x -> get_address_pubkey x |> Or_error.ok_exn)
      in
      let _ =
        printf "SENDERS %s"
        @@ List.fold senders ~init:"" ~f:(fun acc x -> acc ^ x ^ "\n")
      in
      let _ =
        printf "PUBKEYS %s"
        @@ List.fold pubkeys ~init:"" ~f:(fun acc x -> acc ^ x ^ "\n")
      in
      List.exists pubkeys ~f:(fun sender -> sender = sender_pubkey)
  | Error _ ->
      false

let fail_if_already_claimed sender_addr receipt komodo_txid =
  if validate_marker_exists sender_addr receipt komodo_txid then
    Error (Error.of_string "Marker already exists")
  else Ok ()
