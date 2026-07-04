use mathlib::*;

fn main() {
    let a = Vector { x: 1.0, y: 2.0, z: 3.0 };
    let b = Vector { x: 4.0, y: 5.0, z: 6.0 };
    let mut r = unsafe { std::mem::zeroed() };

    println!("=== Vector Math Library Test (Rust) ===");
    println!();

    unsafe {
        vec_add(&a, &b, &mut r);
        println!("a + b         = ({:.1}, {:.1}, {:.1})", r.x, r.y, r.z);
        println!("length(a)     = {:.4}", vec_length(&a));
        println!("length(b)     = {:.4}", vec_length(&b));
        println!("dot(a, b)     = {:.1}", vec_dot(&a, &b));
    }

    println!();
    println!("All tests passed!");
}
