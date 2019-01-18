open Base
open Polymorphic_compare
module F = Obeam.Abstract_format
open Common

type t =
    | TyUnion of t_union_elem list (* has one or more elements *)
    | TyAny
    | TyBottom
 and t_union_elem =
    | TyNumber
    | TyAtom
    | TySingleton of Constant.t
    | TyVar of Type_variable.t
    | TyTuple of t list
    | TyFun of t list * t
[@@deriving sexp_of]

type constraint_ =
    | Eq of t * t
    | Subtype of t * t
    | Conj of constraint_ list
    | Disj of constraint_ list
    | Empty
[@@deriving sexp_of]

(* ref: http://erlang.org/doc/reference_manual/typespec.html *)
let rec pp = function
  | TyUnion tys ->
     List.map ~f:pp_t_union_elem tys |> String.concat ~sep:" | "
  | TyAny -> "any()"
  | TyBottom -> "none()"
and pp_t_union_elem = function
  | TyNumber -> "number()"
  | TyAtom -> "atom()"
  | TySingleton c -> Constant.pp c
  | TyVar var -> Type_variable.to_string var
  | TyTuple ts -> "{" ^ (ts |> List.map ~f:pp |> String.concat ~sep:", ") ^ "}"
  | TyFun (args, ret) ->
     let args_str = "(" ^ (args |> List.map ~f:pp |> String.concat ~sep:", ") ^ ")" in
     let ret_str = pp ret in
     "fun(" ^ args_str ^ " -> " ^ ret_str ^ ")"

let show_constraint c =
  let rec iter indent = function
    | Empty -> ""
    | Eq (ty1, ty2) ->
       !%"%s%s = %s" indent (pp ty1) (pp ty2)
    | Subtype (ty1, ty2) ->
       !%"%s%s <: %s" indent (pp ty1) (pp ty2)
    | Conj cs ->
       let ss = List.map ~f:(iter ("  "^indent)) cs |> List.filter ~f:((<>) "") in
       !%"%sConj {\n%s\n%s}" indent (String.concat ~sep:"\n" ss) indent
    | Disj cs ->
       let ss = List.map ~f:(iter ("  "^indent)) cs |> List.filter ~f:((<>) "") in
       !%"%sDisj {\n%s\n%s}" indent (String.concat ~sep:"\n" ss) indent
  in
  iter "" c

let bool = TyUnion [TySingleton (Atom "true"); TySingleton (Atom "false")]
let of_elem e = TyUnion [e]

(**
   supremum of two types: ty1 ∪ ty2
   assume no type variable in the arguments
 *)
let rec sup ty1 ty2 =
  match (ty1, ty2) with
  | _ when ty1 = ty2 -> ty1
  | (TyAny, _) | (_, TyAny) -> TyAny
  | (TyBottom, ty) | (ty, TyBottom) -> ty
  | (TyUnion tys1, TyUnion tys2) ->
     TyUnion (sup_elems_to_list tys1 tys2) (* has one or more element *)
and sup_elems_to_list store = function
  | [] -> store
  | TyVar _ :: _ -> failwith "cannot reach here"
  | ty1 :: ty1s when List.exists ~f:((=) ty1) store ->
     sup_elems_to_list store ty1s
  | TyNumber :: ty1s ->
     let is_not_number = function TySingleton (Number _) -> false | _ -> true in
     let store' = TyNumber :: List.filter ~f:is_not_number store in
     sup_elems_to_list store' ty1s
  | TySingleton (Number n) :: ty1s when List.exists ~f:((=) TyNumber) store ->
     sup_elems_to_list store ty1s
  | TySingleton (Number n) :: ty1s ->
     sup_elems_to_list (TySingleton (Number n) :: store) ty1s
  | TyAtom :: ty1s ->
     let is_not_atom = function TySingleton (Atom _) -> false | _ -> true in
     let store' = TyAtom :: List.filter ~f:is_not_atom store in
     sup_elems_to_list store' ty1s
  | TySingleton (Atom a) :: ty1s when List.exists ~f:((=) TyAtom) store ->
     sup_elems_to_list store ty1s
  | TySingleton (Atom a) :: ty1s ->
     sup_elems_to_list (TySingleton (Atom a) :: store) ty1s
  | TyTuple ty2s :: ty1s ->
     let store' =
       if List.exists ~f:(function TyTuple tys when List.length ty2s = List.length tys -> true | _ -> false) store then
         List.map ~f:(function
                      | TyTuple tys when List.length ty2s = List.length tys ->
                         List.map2_exn ~f:sup tys ty2s
                         |> fun ty2s' -> TyTuple ty2s'
                      | t -> t)
                  store
       else
         TyTuple ty2s :: store
     in
     sup_elems_to_list store' ty1s
  | TyFun (args, range) :: ty1s ->
     let store' =
       if List.exists ~f:(function TyFun (args0, _) when List.length args0 = List.length args -> true | _ -> false) store then
         List.map ~f:(function
                      | TyFun (args0, range0) when List.length args0 = List.length args ->
                         List.map2_exn ~f:sup args0 args
                         |> fun ty2s' -> TyTuple ty2s'
                      | t -> t)
                  store
       else
         TyFun (args, range) :: store
     in
     sup_elems_to_list store' ty1s

let union_list tys =
  List.reduce_exn ~f:sup tys

(**
   infimum of two types: ty1 ∩ ty2
   assume no type variable in the arguments
 *)
let rec inf ty1 ty2 =  (* ty1 and ty2 should be a TyAny, TyBottom, TyVar or TyUnion *)
  match (ty1, ty2) with
  | _ when ty1 = ty2 -> ty1
  | (TyAny, ty) | (ty, TyAny) -> ty
  | (TyBottom, _) | (_, TyBottom) -> TyBottom
  | (TyUnion tys1, TyUnion tys2) ->
     let ty1s =
       List.cartesian_product tys1 tys2
       |> List.filter_map ~f:(fun (ty1, ty2) -> inf_elem ty1 ty2)
     in
     begin match sup_elems_to_list [] ty1s with
     | [] -> TyBottom
     | ty1s -> TyUnion ty1s
     end
and inf_elem ty1 ty2 =  (* ty1 and ty2 should be a TyNumber, TySingleton, TyAtom, TyTuple or TyFun *)
  match (ty1, ty2) with
  | (TyVar _, _) | (_, TyVar _) -> failwith "cannot reach here"
  | _ when ty1 = ty2 -> Some ty1
  | (TyNumber, TySingleton (Number n)) | (TySingleton (Number n), TyNumber) ->
     Some (TySingleton (Number n))
  | (TyAtom, TySingleton (Atom a)) | (TySingleton (Atom a), TyAtom) ->
     Some (TySingleton (Atom a))
  | (TyTuple tys1, TyTuple tys2) when List.length tys1 = List.length tys2 ->
     List.map2_exn ~f:inf tys1 tys2
     |> fun tys -> Some (TyTuple tys)
  | (TyFun (args1, range1), TyFun (args2, range2)) when List.length args1 = List.length args2 ->
     let args' = List.map2_exn ~f:inf args1 args2 in
     let range' = inf range1 range2 in
     Some (TyFun (args', range'))
  | (_, _) ->
     None

let rec of_erlang = function
  | F.TyUnion (_line, ts) ->
     TyUnion (List.map ~f:elem_of_erlang ts)
  | t ->
     of_elem (elem_of_erlang t)
and elem_of_erlang = function
  | F.TyPredef (_line, "number", []) -> TyNumber
  | F.TyLit (LitAtom (_, atom)) -> TySingleton (Atom atom)
  | F.TyVar (_line, v) -> TyVar (Type_variable.of_string v)
  | TyFun (_line, _, args, range) ->
     TyFun(List.map ~f:of_erlang args, of_erlang range)
  | other ->
     failwith (!%"not implemented conversion from type: %s" (F.sexp_of_type_t other |> Sexp.to_string_hum))