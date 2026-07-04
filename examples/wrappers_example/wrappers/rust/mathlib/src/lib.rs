#![allow(non_camel_case_types, non_snake_case)]

#[repr(C)]
pub struct Vector {
    pub x: f64,
    pub y: f64,
    pub z: f64,
}

pub const OP_ADD: i32 = 0;
pub const OP_SUB: i32 = 1;
pub const OP_MUL: i32 = 2;
pub const OP_DIV: i32 = 3;

extern "C" {
    /// Add two vectors, store result in `res`
    pub fn vec_add(a: *const Vector, b: *const Vector, res: *mut Vector) -> ();

    /// Compute the length (magnitude) of a vector
    pub fn vec_length(v: *const Vector) -> f64;

    /// Scale a vector in-place by a factor
    pub fn vec_scale(v: *const Vector, factor: f64) -> ();

    /// Compute the dot product of two vectors
    pub fn vec_dot(a: *const Vector, b: *const Vector) -> f64;
}
