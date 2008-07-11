(* Bitmatch persistent patterns.
 * Copyright (C) 2008 Red Hat Inc., Richard W.M. Jones
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2 of the License, or (at your option) any later version,
 * with the OCaml linking exception described in COPYING.LIB.
 *
 * This library is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with this library; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA
 *
 * $Id$
 *)

open Printf

open Camlp4.PreCast
open Syntax
open Ast

type patt = Camlp4.PreCast.Syntax.Ast.patt
type expr = Camlp4.PreCast.Syntax.Ast.expr
type loc_t = Camlp4.PreCast.Syntax.Ast.Loc.t

(* Field.  In bitmatch (patterns) the type is [patt field].  In
 * BITSTRING (constructor) the type is [expr field].
 *)
type 'a field = {
  field : 'a;				(* field ('a is either patt or expr) *)
  flen : expr;				(* length in bits, may be non-const *)
  endian : endian_expr;			(* endianness *)
  signed : bool;			(* true if signed, false if unsigned *)
  t : field_type;			(* type *)
  _loc : Loc.t;				(* location in source code *)
  offset : expr option;			(* offset expression *)
}
and field_type = Int | String | Bitstring (* field type *)
and endian_expr =
  | ConstantEndian of Bitmatch.endian	(* a constant little/big/nativeendian *)
  | EndianExpr of expr			(* an endian expression *)

type pattern = patt field list

type constructor = expr field list

type named = string * alt
and alt =
  | Pattern of pattern
  | Constructor of constructor

(* Work out if an expression is an integer constant.
 *
 * Returns [Some i] if so (where i is the integer value), else [None].
 *
 * Fairly simplistic algorithm: we can only detect simple constant
 * expressions such as [k], [k+c], [k-c] etc.
 *)
let rec expr_is_constant = function
  | <:expr< $int:i$ >> ->		(* Literal integer constant. *)
    Some (int_of_string i)
  | <:expr< $a$ + $b$ >> ->		(* Addition of constants. *)
    (match expr_is_constant a, expr_is_constant b with
     | Some a, Some b -> Some (a+b)
     | _ -> None)
  | <:expr< $a$ - $b$ >> ->		(* Subtraction. *)
    (match expr_is_constant a, expr_is_constant b with
     | Some a, Some b -> Some (a-b)
     | _ -> None)
  | <:expr< $a$ * $b$ >> ->	        (* Multiplication. *)
    (match expr_is_constant a, expr_is_constant b with
     | Some a, Some b -> Some (a*b)
     | _ -> None)
  | <:expr< $a$ / $b$ >> ->	        (* Division. *)
    (match expr_is_constant a, expr_is_constant b with
     | Some a, Some b -> Some (a/b)
     | _ -> None)
  | <:expr< $a$ lsl $b$ >> ->	        (* Shift left. *)
    (match expr_is_constant a, expr_is_constant b with
     | Some a, Some b -> Some (a lsl b)
     | _ -> None)
  | <:expr< $a$ lsr $b$ >> ->	        (* Shift right. *)
    (match expr_is_constant a, expr_is_constant b with
     | Some a, Some b -> Some (a lsr b)
     | _ -> None)
  | _ -> None				(* Anything else is not constant. *)

let string_of_field_type = function
  | Int -> "int"
  | String -> "string"
  | Bitstring -> "bitstring"

let patt_printer = function
  | <:patt< $lid:id$ >> -> id
  | <:patt< _ >> -> "_"
  | _ -> "[pattern]"

let expr_printer = function
  | <:expr< $lid:id$ >> -> id
  | <:expr< $int:i$ >> -> i
  | _ -> "[expression]"

let _string_of_field { flen = flen;
		       endian = endian; signed = signed; t = t;
		       _loc = _loc;
		       offset = offset } =
  let flen =
    match expr_is_constant flen with
    | Some i -> string_of_int i
    | None -> "[non-const-len]" in
  let endian =
    match endian with
    | ConstantEndian endian -> Bitmatch.string_of_endian endian
    | EndianExpr _ -> "endian([expr])" in
  let signed = if signed then "signed" else "unsigned" in
  let t = string_of_field_type t in

  let offset =
    match offset with
    | None -> ""
    | Some expr ->
	match expr_is_constant expr with
	| Some i -> sprintf ", offset(%d)" i
	| None -> sprintf ", offset([expr])" in

  let loc_fname = Loc.file_name _loc in
  let loc_line = Loc.start_line _loc in
  let loc_char = Loc.start_off _loc - Loc.start_bol _loc in

  sprintf "%s : %s, %s, %s%s (* %S:%d %d *)"
    flen t endian signed offset loc_fname loc_line loc_char

let rec string_of_pattern_field ({ field = patt } as field) =
  sprintf "%s : %s" (patt_printer patt) (_string_of_field field)

and string_of_constructor_field ({ field = expr } as field) =
  sprintf "%s : %s" (expr_printer expr) (_string_of_field field)

let string_of_pattern pattern =
  "{ " ^
    String.concat ";\n  " (List.map string_of_pattern_field pattern) ^
    " }\n"

let string_of_constructor constructor =
  "{ " ^
    String.concat ";\n  " (List.map string_of_constructor_field constructor) ^
    " }\n"

let named_to_channel chan n = Marshal.to_channel chan n []

let named_to_string n = Marshal.to_string n []

let named_to_buffer str ofs len n = Marshal.to_buffer str ofs len n []

let named_from_channel = Marshal.from_channel

let named_from_string = Marshal.from_string

let create_pattern_field _loc =
  {
    field = <:patt< _ >>;
    flen = <:expr< 32 >>;
    endian = ConstantEndian Bitmatch.BigEndian;
    signed = false;
    t = Int;
    _loc = _loc;
    offset = None;
  }

let set_lident_patt field id =
  let _loc = field._loc in
  { field with field = <:patt< $lid:id$ >> }
let set_int_patt field i =
  let _loc = field._loc in
  { field with field = <:patt< $`int:i$ >> }
let set_string_patt field str =
  let _loc = field._loc in
  { field with field = <:patt< $str:str$ >> }
let set_unbound_patt field =
  let _loc = field._loc in
  { field with field = <:patt< _ >> }
let set_patt field patt = { field with field = patt }
let set_length_int field flen =
  let _loc = field._loc in
  { field with flen = <:expr< $`int:flen$ >> }
let set_length field flen = { field with flen = flen }
let set_endian field endian = { field with endian = ConstantEndian endian }
let set_endian_expr field expr = { field with endian = EndianExpr expr }
let set_signed field signed = { field with signed = signed }
let set_type_int field = { field with t = Int }
let set_type_string field = { field with t = String }
let set_type_bitstring field = { field with t = Bitstring }
let set_location field loc = { field with _loc = loc }
let set_offset_int field i =
  let _loc = field._loc in
  { field with offset = Some <:expr< $`int:i$ >> }
let set_offset field expr = { field with offset = Some expr }
let set_no_offset field = { field with offset = None }

let create_constructor_field _loc =
  {
    field = <:expr< 0 >>;
    flen = <:expr< 32 >>;
    endian = ConstantEndian Bitmatch.BigEndian;
    signed = false;
    t = Int;
    _loc = _loc;
    offset = None;
  }

let set_lident_expr field id =
  let _loc = field._loc in
  { field with field = <:expr< $lid:id$ >> }
let set_int_expr field i =
  let _loc = field._loc in
  { field with field = <:expr< $`int:i$ >> }
let set_string_expr field str =
  let _loc = field._loc in
  { field with field = <:expr< $str:str$ >> }
let set_expr field expr =
  let _loc = field._loc in
  { field with field = expr }

let get_patt field = field.field
let get_expr field = field.field
let get_length field = field.flen
let get_endian field = field.endian
let get_signed field = field.signed
let get_type field = field.t
let get_location field = field._loc
let get_offset field = field.offset
