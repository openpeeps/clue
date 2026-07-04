require "./wrappers/crystal/mathlib/src/mathlib"

a = LibMathlib::Vector.new
a.x = 1.0_f64
a.y = 2.0_f64
a.z = 3.0_f64

b = LibMathlib::Vector.new
b.x = 4.0_f64
b.y = 5.0_f64
b.z = 6.0_f64

r = LibMathlib::Vector.new

LibMathlib.vec_add(pointerof(a), pointerof(b), pointerof(r))
puts "a + b = (#{r.x}, #{r.y}, #{r.z})"
puts "length(a) = #{LibMathlib.vec_length(pointerof(a))}"
puts "dot(a, b) = #{LibMathlib.vec_dot(pointerof(a), pointerof(b))}"
