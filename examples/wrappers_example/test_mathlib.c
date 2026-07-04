#include "wrappers/c/mathlib.h"
#include <stdio.h>
#include <math.h>

int main() {
    Vector a = {1.0, 2.0, 3.0};
    Vector b = {4.0, 5.0, 6.0};
    Vector r;

    printf("=== Vector Math Library Test ===\n\n");

    vec_add(&a, &b, &r);
    printf("a + b         = (%.1f, %.1f, %.1f)\n", r.x, r.y, r.z);

    printf("length(a)     = %.4f\n", vec_length(&a));
    printf("length(b)     = %.4f\n", vec_length(&b));
    printf("dot(a, b)     = %.1f\n", vec_dot(&a, &b));

    vec_scale(&a, 2.0);
    printf("a * 2         = (%.1f, %.1f, %.1f)\n", a.x, a.y, a.z);

    printf("\nAll tests passed!\n");
    return 0;
}
