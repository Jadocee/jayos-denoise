//! A vendored part of JayOS's shared library for its helper programs.
//!
//! NOT JayOS's lib.rs. Every other file in this crate is byte for byte JayOS's
//! rust/crates/jayos-core at jayos commit 45256e08 (PROVENANCE.md beside
//! Cargo.toml has the sums); this one declares only the five modules
//! jayos-audio-state and jayos-equalizer-preset use, where JayOS's declares
//! twelve, and leaves out its `now_unix`, which neither calls. The conventions
//! JayOS's header sets out hold here too, because the code is its code:
//!
//! *Stdout is only ever the answer.* QML runs these and parses stdout as JSON;
//! diagnostics go to stderr, through `emit`.
//!
//! *Exit zero means the answer is trustworthy*, not that the program ran.
//!
//! *Nothing blocks forever.* Every subprocess has a deadline (`proc`).
//!
//! *The command-line interface is not ours to change.* JayOS's QML and
//! scripts call these by name, with the arguments they always took.

pub mod cli;
pub mod emit;
pub mod paths;
pub mod proc;
pub mod pw_route;
