#!/usr/bin/env ruby
# Clue Ruby PluginKit Example
# Load and test the compiled Nim extension (.bundle)

require_relative 'build/Example'

puts "=== Testing #{Example.name} module ==="
puts

# hello(name) — string param
Example.hello("Ruby")

# greet(name) — returns a Ruby string
puts Example.greet("World")

# double(n) — returns integer
puts "21 doubled = #{Example.double(21)}"

# is_positive(n) — returns boolean
puts "3.14 positive? #{Example.is_positive(3.14)}"
puts "-1.0 positive? #{Example.is_positive(-1.0)}"

# repeat(msg, count) — returns an array
result = Example.repeat("go", 3)
puts "repeat: #{result.inspect}"
