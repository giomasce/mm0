import data.bitvec

def bitvec.singleton (b : bool) : bitvec 1 := vector.cons b vector.nil

@[reducible] def byte := bitvec 8

def byte.to_nat : byte → ℕ := bitvec.to_nat

@[reducible] def short := bitvec 16

@[reducible] def word := bitvec 32

@[reducible] def qword := bitvec 64

def of_bits : list bool → nat
| [] := 0
| (b :: l) := nat.bit b (of_bits l)

inductive split_bits : ℕ → list (Σ n, bitvec n) → Prop
| nil : split_bits 0 []
| zero {b l} : split_bits b l → split_bits b (⟨0, vector.nil⟩ :: l)
| succ {b n l bs} :
  split_bits b (⟨n, bs⟩ :: l) →
  split_bits (nat.div2 b) (⟨n + 1, vector.cons (nat.bodd b) bs⟩ :: l)

def from_list_byte : list byte → ℕ
| [] := 0
| (b :: l) := b.to_nat + 0x100 * from_list_byte l

inductive bits_to_byte {n} (m) (w : bitvec n) : list byte → Prop
| mk (bs : vector byte m) : split_bits w.to_nat (bs.1.map (λ b, ⟨8, b⟩)) →
  bits_to_byte bs.1

def short.to_list_byte : short → list byte → Prop := bits_to_byte 2

def word.to_list_byte : word → list byte → Prop := bits_to_byte 4

def qword.to_list_byte : qword → list byte → Prop := bits_to_byte 8

def EXTS_aux : list bool → bool → ∀ {m}, bitvec m
| []     b m     := vector.repeat b _
| (a::l) _ 0     := vector.nil
| (a::l) _ (m+1) := vector.cons a (EXTS_aux l a)

def EXTS {m n} (v : bitvec n) : bitvec m := EXTS_aux v.1 ff

def EXTZ_aux : list bool → ∀ {m}, bitvec m
| []     m     := vector.repeat ff _
| (a::l) 0     := vector.nil
| (a::l) (m+1) := vector.cons a (EXTS_aux l a)

def EXTZ {m n} (v : bitvec n) : bitvec m := EXTZ_aux v.1

def bitvec.update0_aux : list bool → ∀ {n}, bitvec n → bitvec n
| []     n     v := v
| (a::l) 0     v := v
| (a::l) (n+1) v := vector.cons a (bitvec.update0_aux l v.tail)

def bitvec.update_aux : ℕ → list bool → ∀ {n}, bitvec n → bitvec n
| 0     l n     v := bitvec.update0_aux l v
| (m+1) l 0     v := v
| (m+1) l (n+1) v := vector.cons v.head (bitvec.update_aux m l v.tail)

def bitvec.update {m n} (v1 : bitvec n) (index : ℕ) (v2 : bitvec m) : bitvec n :=
bitvec.update_aux index v2.1 v1

class byte_encoder (α : Type*) := (f : α → list byte → Prop)

def encodes {α : Type*} [E : byte_encoder α] : α → list byte → Prop := E.f

def encodes_with {α : Type*} [byte_encoder α]
  (a : α) (l1 l2 : list byte) : Prop :=
∃ l, encodes a l ∧ l2 = l ++ l1

def encodes_start {α : Type*} [byte_encoder α]
  (a : α) (l : list byte) : Prop :=
∃ l', encodes_with a l' l

inductive encodes_list {α} [byte_encoder α] : list α → list byte → Prop
| nil : encodes_list [] []
| cons {a as l ls} : encodes a l → encodes_list (a :: as) (l ++ ls)

inductive encodes_list_start {α} [byte_encoder α] : list α → list byte → Prop
| nil {l} : encodes_list_start [] l
| cons {a as l ls} : encodes a l → encodes_list_start (a :: as) (l ++ ls)

instance : byte_encoder unit := ⟨λ _ l, l = []⟩
instance : byte_encoder byte := ⟨λ b l, l = [b]⟩
instance : byte_encoder short := ⟨short.to_list_byte⟩
instance : byte_encoder word := ⟨word.to_list_byte⟩
instance : byte_encoder qword := ⟨qword.to_list_byte⟩
instance : byte_encoder (list byte) := ⟨eq⟩
instance {n} : byte_encoder (vector byte n) := ⟨λ x l, x.1 = l⟩

instance {α β} [byte_encoder α] [byte_encoder β] : byte_encoder (α × β) :=
⟨λ ⟨a, b⟩ l, ∃ l1 l2, encodes a l1 ∧ encodes a l2 ∧ l = l1 ++ l2⟩

structure pstate_result (σ α : Type*) :=
(safe : Prop)
(P : α → σ → Prop)
(good : safe → ∃ a s, P a s)

def pstate (σ α : Type*) := σ → pstate_result σ α

inductive pstate_pure_P {σ α : Type*} (a : α) (s : σ) : α → σ → Prop
| mk : pstate_pure_P a s

inductive pstate_map_P {σ α β} (f : α → β) (x : pstate_result σ α) : β → σ → Prop
| mk (a s') : x.P a s' → pstate_map_P (f a) s'

def pstate_bind_safe {σ α β} (x : pstate σ α) (f : α → pstate σ β) (s : σ) : Prop :=
(x s).safe ∧ ∀ a s', (x s).P a s' → (f a s').safe

def pstate_bind_P {σ α β} (x : pstate σ α) (f : α → pstate σ β) (s : σ) (b : β) (s' : σ) : Prop :=
∃ a s1, (x s).P a s1 ∧ (f a s1).P b s'

instance {σ} : monad (pstate σ) :=
{ pure := λ α a s, ⟨true, pstate_pure_P a s, λ _, ⟨_, _, ⟨a, s⟩⟩⟩,
  map := λ α β f x s, ⟨(x s).1, pstate_map_P f (x s), λ h,
    let ⟨a, s', h⟩ := (x s).good h in ⟨_, _, ⟨_, _, _, h⟩⟩⟩,
  bind := λ α β x f s, ⟨pstate_bind_safe x f s, pstate_bind_P x f s,
    λ ⟨h₁, h₂⟩, let ⟨a, s1, hx⟩ := (x s).good h₁,
      ⟨b, s2, hf⟩ := (f a s1).good (h₂ a s1 hx) in
      ⟨b, s2, ⟨_, _, hx, hf⟩⟩⟩ }

def pstate.lift {σ α} (f : σ → α → σ → Prop) : pstate σ α := λ s, ⟨_, f s, id⟩

inductive pstate.get' {σ} (s : σ) : σ → σ → Prop
| mk : pstate.get' s s
def pstate.get {σ} : pstate σ σ := pstate.lift pstate.get'

def pstate.put {σ} (s : σ) : pstate σ unit := pstate.lift $ λ _ _, eq s

def pstate.assert {σ α} (p : σ → α → Prop) : pstate σ α :=
pstate.lift $ λ s a s', p s a ∧ s = s'

def pstate.modify {σ} (f : σ → σ) : pstate σ unit :=
pstate.lift $ λ s _ s', s' = f s

def pstate.any {σ α} : pstate σ α := pstate.assert $ λ _ _, true

def pstate.fail {σ α} : pstate σ α := pstate.assert $ λ _ _, false
