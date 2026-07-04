package main

import (
	"fmt"
	"mathlib"
)

func main() {
	a := mathlib.Vector{X: 1.0, Y: 2.0, Z: 3.0}
	b := mathlib.Vector{X: 4.0, Y: 5.0, Z: 6.0}
	var r mathlib.Vector

	fmt.Println("=== Vector Math Library Test (Go) ===")
	fmt.Println()

	mathlib.Vec_add(&a, &b, &r)
	fmt.Printf("a + b         = (%.1f, %.1f, %.1f)\n", r.X, r.Y, r.Z)

	fmt.Printf("length(a)     = %.4f\n", mathlib.Vec_length(&a))
	fmt.Printf("length(b)     = %.4f\n", mathlib.Vec_length(&b))
	fmt.Printf("dot(a, b)     = %.1f\n", mathlib.Vec_dot(&a, &b))

	mathlib.Vec_scale(&a, 2.0)
	fmt.Printf("a * 2         = (%.1f, %.1f, %.1f)\n", a.X, a.Y, a.Z)

	fmt.Println()
	fmt.Println("All tests passed!")
}
