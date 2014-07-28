open Longident
open Location
open Asttypes
open Parsetree
open Ast_helper
open Ast_convenience

let prefix = "enum"
let raise_errorf = Ppx_deriving.raise_errorf

let () =
  let mappings_of_type type_decl =
    let map acc mappings attrs constr_name =
      let value =
        match Ppx_deriving.attr ~prefix "value" attrs |>
              Ppx_deriving.Arg.(payload ~name:"Enum" int) with
        | Some idx -> idx | None -> acc
      in
      (value + 1, (value, constr_name) :: mappings)
    in
    let kind, (_, mappings) =
      match type_decl.ptype_kind, type_decl.ptype_manifest with
      | Ptype_variant constrs, _ ->
        `Regular,
        List.fold_left (fun (acc, mappings) { pcd_name; pcd_args; pcd_attributes; pcd_loc } ->
            if pcd_args <> [] then
              raise_errorf ~loc:pcd_loc "Enum can be derived only for argumentless constructors";
            map acc mappings pcd_attributes pcd_name)
          (0, []) constrs
      | Ptype_abstract, Some { ptyp_desc = Ptyp_variant (constrs, Closed, None); ptyp_loc } ->
        `Polymorphic,
        List.fold_left (fun (acc, mappings) row_field ->
            (* TODO: use row_field location instead of ptyp_loc when fixed in Parsetree *)
            match row_field with
            | Rinherit _ ->
              raise_errorf ~loc:ptyp_loc "Enum cannot be derived for inherited variant cases"
            | Rtag (name, attrs, true, []) ->
              map acc mappings attrs { txt = name; loc = ptyp_loc }
            | Rtag _ ->
              raise_errorf ~loc:ptyp_loc "Enum can be derived only for argumentless constructors")
          (0, []) constrs
      | _ -> raise_errorf ~loc:type_decl.ptype_loc "Enum can be derived only for variants"
    in
    let rec check_dup mappings =
      match mappings with
      | (a, { txt=atxt; loc=aloc }) :: (b, { txt=btxt; loc=bloc }) :: _ when a = b ->
        let sigil = match kind with `Regular -> "" | `Polymorphic -> "`" in
        let sub = [Location.errorf ~loc:bloc "Same as for %s%s" sigil btxt] in
        raise_errorf ~sub ~loc:aloc "Enum: duplicate value %d for constructor %s%s" a sigil atxt
      | _ :: rest -> check_dup rest
      | [] -> ()
    in
    mappings |> List.stable_sort (fun (a,_) (b,_) -> compare a b) |> check_dup;
    kind, mappings
  in
  let str_of_type ~options ~path ({ ptype_loc = loc } as type_decl) =
    let kind, mappings = mappings_of_type type_decl in
    let patt name =
      match kind with
      | `Regular -> Pat.construct (mknoloc (Lident name)) None
      | `Polymorphic -> Pat.variant name None
    and expr name =
      match kind with
      | `Regular -> Exp.construct (mknoloc (Lident name)) None
      | `Polymorphic -> Exp.variant name None
    in
    let to_enum_cases =
      List.map (fun (value, { txt = name }) ->
        Exp.case (patt name) (int value)) mappings
    and from_enum_cases =
      List.map (fun (value, { txt = name }) ->
        Exp.case (pint value) (constr "Some" [expr name])) mappings @
      [Exp.case (Pat.any ()) (constr "None" [])]
    and indexes = List.map fst mappings in
    [Vb.mk (pvar (Ppx_deriving.mangle_type_decl (`Prefix "min") type_decl))
           (int (List.fold_left min max_int indexes));
     Vb.mk (pvar (Ppx_deriving.mangle_type_decl (`Prefix "max") type_decl))
           (int (List.fold_left max min_int indexes));
     Vb.mk (pvar (Ppx_deriving.mangle_type_decl (`Suffix "to_enum") type_decl))
           (Exp.function_ to_enum_cases);
     Vb.mk (pvar (Ppx_deriving.mangle_type_decl (`Suffix "of_enum") type_decl))
           (Exp.function_ from_enum_cases)]
  in
  let sig_of_type ~options ~path type_decl =
    let typ = Ppx_deriving.core_type_of_type_decl type_decl in
    [Sig.value (Val.mk (mknoloc (Ppx_deriving.mangle_type_decl (`Prefix "min") type_decl))
               [%type: int]);
     Sig.value (Val.mk (mknoloc (Ppx_deriving.mangle_type_decl (`Prefix "max") type_decl))
               [%type: int]);
     Sig.value (Val.mk (mknoloc (Ppx_deriving.mangle_type_decl (`Suffix "to_enum") type_decl))
               [%type: [%t typ] -> int]);
     Sig.value (Val.mk (mknoloc (Ppx_deriving.mangle_type_decl (`Suffix "of_enum") type_decl))
               [%type: int -> [%t typ] option])]
  in
  Ppx_deriving.(register "Enum" {
    core_type = (fun { ptyp_loc } ->
      raise_errorf ~loc:ptyp_loc "[%%derive.Enum] is not supported");
    structure = (fun ~options ~path type_decls ->
      [Str.value Nonrecursive (List.concat (List.map (str_of_type ~options ~path) type_decls))]);
    signature = (fun ~options ~path type_decls ->
      List.concat (List.map (sig_of_type ~options ~path) type_decls));
  })