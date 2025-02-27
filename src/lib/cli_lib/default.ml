(* Default values for cli flags *)
(* A payment requires 2 SNARKS, so this should always >= 2x the snark fee. *)
let transaction_fee = Currency.Fee.of_int 5

(*Fee for a snark bundle*)
let snark_worker_fee = Currency.Fee.of_int 1

let work_reassignment_wait = 420000
