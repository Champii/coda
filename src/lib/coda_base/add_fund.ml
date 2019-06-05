[%%import
"../../config.mlh"]

open Core
open Module_version

module Poly = struct
  module Stable = struct
    module V1 = struct
      module T = struct
        type ('payload, 'pk, 'signature) t =
          {payload: 'payload; sender: 'pk; signature: 'signature}
        [@@deriving bin_io, eq, sexp, hash, yojson, version]
      end

      include T
    end

    module Latest = V1
  end

  type ('payload, 'pk, 'signature) t =
        ('payload, 'pk, 'signature) Stable.Latest.t =
    {payload: 'payload; sender: 'pk; signature: 'signature}
  [@@deriving eq, sexp, hash, yojson]
end

module Stable = struct
  module V1 = struct
    module T = struct
      type t = string [@@deriving bin_io, eq, sexp, hash, yojson, version]
    end

    include T
    include Registration.Make_latest_version (T)
  end

  module Latest = V1

  module Module_decl = struct
    let name = "add_fund"

    type latest = Latest.t
  end

  module Registrar = Registration.Make (Module_decl)
  module Registered_V1 = Registrar.Register (V1)
end

type t = Stable.Latest.t [@@deriving sexp, yojson, hash]

type value = t
