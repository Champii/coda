# Scan State Refactoring

The parallel scan state currently is a full-binary tree with leaves (or called `Base` nodes) having values of type `Transaction_with_witness.t` and intermediate nodes (or called `Merge` nodes) having values of type `Ledger_proof_with_sok_message.t`

Everytime a diff is applied, the transactions are transformed to new base jobs and added to the scan state. The diff also includes completed works that correspond to a sequence of jobs that already exist on the scan state. These, when added to scan state, create new merge jobs except when it is for the root node in which case the proof is simply returned as the result.

Currently, parallel scan is implemented using arrays and involve a lot of index manipulation. This makes the code difficult to read and maintain. This refactoring aims to make the structure declarative and more "functional" given that we can lax a bit on the efficiency since there are other expensive operations(sparse ledgers for witness) in `apply_diff`.

The following constants dictate the structure and behaviour of the scan state.

1. *Transaction_capacity_log_2*: $2^{transaction\_capacity\_log\_2}$ is the maximum number of transactions (or base jobs) that can be added per block and the maximum number of proofs that is to be done is $2^{transaction\_capacity\_log\_2 + 1} - 1$. Prorated work for a transaction is two proofs except for transaction that occupies the last slot which is just one proof.

2. *Work_delay*: Every block adds new jobs on to the scan state; some base jobs and others merge jobs. Since generating snarks take time, all the work that was added in the current block may not be completed by the time next block is generated. Therefore, we add *work_delay* extra trees to accumulate enough work over *work_delay* blocks. This ensures the amount of work that is required to be completed are created in blocks before the last *work_delay* blocks which would give enough time for the snarks to be generated.

Given these two constants, the parallel scan state will now be a forest of at most $(transaction\_capacity\_log\_2 + 1) * (work\_delay + 1) + 1$ trees with each tree having exactly $2^{transaction\_capacity\_log\_2}$ leaves. The following snapshots of the scan state after each block with $transaction\_capacity\_log\_2=2$ and $work\_delay=1$ will help visualizing how this would work. Having a *work_delay* of 1 ensures the work that needs to be done is from blocks before the last block.

Note: M*i* for merge nodes and B*i* for base nodes where *i* is the block in which the work was added

Genesis:

         _
      _      _
    _   _  _   _

Block 1: Add four transactions (B1's); there's no work yet that needs to be done

           _                 _
       _       _         _       _
     _   _   _   _    B1   B1  B1  B1

Block 2: Add four transactions (B2's); there's no work yet that needs to be done

           _                  _                   _
       _       _         _        _          _        _
     _   _   _   _    B2   B2  B2   B2    B1   B1  B1   B1

Block 3: Add four transactions (B3's) and complete four proofs (B1's) because those are only the ones that were added before block 2. Completing these creates two new merge jobs (M3's)

          _              _                     _                   _
       _     _       _       _             _        _         M3      M3
     _  _  _  _   B3   B3   B3   B3    B2   B2  B2   B2    B1   B1  B1   B1

Block 4: Add four transactions (B4's) and complete four proofs (B2's) because those are only the ones that were added before block 3. Completing these creates two new merge jobs (M4's)

          _               _                _                     _                   _
       _     _       _        _        _        _           M4      M4         M3       M3
     _  _  _  _    B4  B4  B4  B4   B3   B3   B3   B3    B2   B2  B2   B2    B1   B1  B1   B1

Block 5: Add four transactions (B5's) and complete six proofs (B3's and M3's). Creates three new merge jobs (M5's)

          _              _                  _                _                     _                   M5
       _     _       _        _        _        _        M5        M5           M4      M4        M3       M3
     _  _  _  _    B5  B5  B5  B5    B4  B4  B4  B4   B3   B3   B3   B3    B2   B2  B2   B2    B1   B1  B1   B1

Block 6: Add four transactions (B6's) and complete six proofs (B4's and M4's). Creates three new merge jobs (M6's)

          _              _                  _                _                  _                     M6                 M5
       _     _        _      _         _        _        M6      M6        M5        M5           M4      M4        M3       M3
     _  _  _  _    B6  B6  B6  B6    B5  B5  B5  B5    B4  B4  B4  B4   B3   B3   B3   B3    B2   B2  B2   B2    B1   B1  B1   B1

Block 7: Add four transactions (B7's) and complete seven proofs (B5's and M5's). Creates three new merge jobs (M7's) and also the M5 proof at the root of the last tree is returned as a result and the tree itself is deleted. This is the ledger proof corresponding to the transactions added in block 1.

          _              _                 _                  _                 _                 M7                  M6
       _     _        _     _           _      _          M7     M7        M6      M6        M5        M5         M4      M4
     _  _  _  _    B7  B7  B7  B7    B6  B6  B6  B6    B5  B5  B5  B5    B4  B4  B4  B4   B3   B3   B3   B3    B2   B2  B2   B2

Block 8: Add two transactions (B8's) and complete four proofs (B6's). Creates two new merge jobs (M8's). Note that only four proofs are needed for adding two transactions.

          _                _                 _                  _                 _                M7                  M6
       _     _          _     _          M8     M8         M7     M7        M6      M6        M5        M5         M4      M4
     B8  B8  _  _    B7  B7  B7  B7    B6  B6  B6  B6    B5  B5  B5  B5    B4  B4  B4  B4   B3   B3   B3   B3    B2   B2  B2   B2

Block 9: Three transactions (B9's); complete three proofs (M6's) for the slots to be occupied in the second tree. Four proofs were added in the previous block and thereofre only three more needs to be done (maximum work given the constants is 7). For the thrid transaction, complete the next two proofs (B7's). The M6 proof from the last tree is returned as the ledger proof.

          _                _                _                 _                  _                M9                M7
       _     _        _      _           M9      _         M8     M8         M7     M7         M6      M6        M5        M5
     B9  _  _  _    B8  B8  B9  B9    B7  B7  B7  B7    B6  B6  B6  B6    B5  B5  B5  B5    B4  B4  B4  B4   B3   B3   B3   B3

Block 10: Four transactions, complete seven proofs (B7's and M7's)

          _                  _                   _                _                 _                M10                M9
       _     _          _         _          _      _         M9      M10       M8     M8         M7     M7         M6      M6
     B10  _  _  _    B9  B10  B10  B10    B8  B8  B9  B9    B7  B7  B7  B7    B6  B6  B6  B6    B5  B5  B5  B5    B4  B4  B4  B4

Block 11: three transactions, complete seven proofs (B8, B8, B9, B9, M8, M8, M9) in that order and return the M9 proof

          _                _                      _                 _                  _                M11               M10
       _     _         _         _          _         _         M11    M11         M9      M10       M8     M8         M7     M7
     _  _  _  _    B10  B11  B11  B11    B9  B10  B10  B10    B8  B8  B9  B9    B7  B7  B7  B7    B6  B6  B6  B6    B5  B5  B5  B5

 The number work that needs to be done is predetermined and depends on the number of slots occupied and which slot is occupied. The last slot of a tree requires only 1 proof to be done. This is because the total work that needs to be done is $2^{transaction\_capacity\_log\_2 - 1}$. The amount of work is always fixed based on the position of the slots being filled.
 Having this constraint ensures:

1. Multiple proofs are not emitted per update

2. The merge node that is to be updated after adding proofs corresponding to its children is always empty. This allows us keep the number of trees to a minimum of $work\_delay+2$.

The latency in this impl is as good as it can get because it emits a ledger proof for every $2^{transaction\_capacity\_log\_2}$ transactions.

## Types

```ocaml

type sequence_number = int

type 'd base = ('d * sequence_number) option

type 'a merge =
    | Empty
    | Part of 'a
    | Bcomp of ('a * 'a * sequence_number)


type ('a, 'd) tree = Base of 'd | Merge of 'a * ('a * 'a, 'd * 'd) tree
(*This structure works well because we always complete all the nodes on a specific level before proceeding to the next level and therefore O(log n) access for updating any number of nodes *)

type ('a, 'd) t =
    {trees: ('a merge, 'd base) tree list
    ; acc: int * ('a * 'd list) option
    (*last emitted proof and the corresponding transactions*)
    ; curr_job_seq_no: int
    (*Sequence number for the jobs added every block*)
    ; max_base_jobs: int
    (*2^transaction_capacity_log_2*)
    ; delay: int }

val update :: ('a, 'd) t -> data:'d list -> work:'a list -> ('a, 'd) t
(*T(n) = O((log n)^2) *)

...

```
