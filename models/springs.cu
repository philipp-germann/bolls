// Integrate N-body problem with springs between all bodies.
#include <assert.h>
#include <iostream>
#include <sstream>
#include <cmath>
#include <sys/stat.h>

#include "../lib/vtk.cuh"
#include "../lib/n2n.cuh"


const float L_0 = 0.5; // Relaxed spring length
const float delta_t = 0.001;
const uint N_BODIES = 800;
const uint N_TIME_STEPS = 100;

__device__ __managed__ float3 X[N_BODIES];


__device__ float3 body_body_force(float3 Xi, float3 Xj) {
    float3 r;
    float3 dF = {0.0f, 0.0f, 0.0f};
    r.x = Xj.x - Xi.x;
    r.y = Xj.y - Xi.y;
    r.z = Xj.z - Xi.z;
    float dist = sqrtf(r.x*r.x + r.y*r.y + r.z*r.z);
    if (dist > 1e-8) {
        dF.x += r.x*(dist - L_0)/dist;
        dF.y += r.y*(dist - L_0)/dist;
        dF.z += r.z*(dist - L_0)/dist;
    }
    assert(dF.x == dF.x); // For NaN f != f.
    return dF;
}


int main(int argc, const char* argv[]) {
    assert(N_BODIES % TILE_SIZE == 0);

    // Prepare initial state
    float r_max = pow(N_BODIES/0.75, 1./3)*L_0/2; // Sphere packing
    for (int i = 0; i < N_BODIES; i++) {
        float r = r_max*pow(rand()/(RAND_MAX + 1.), 1./3);
        float theta = rand()/(RAND_MAX + 1.)*2*M_PI;
        float phi = acos(2.*rand()/(RAND_MAX + 1.) - 1);
        X[i].x = r*sin(theta)*sin(phi);
        X[i].y = r*cos(theta)*sin(phi);
        X[i].z = r*cos(phi);
    }

    // Integrate body positions
    mkdir("output", 755);
    for (int time_step = 0; time_step <= N_TIME_STEPS; time_step++) {
        char file_name[22];
        sprintf(file_name, "output/springs_%03i.vtk", time_step);
        write_positions(file_name, N_BODIES, X);

        if (time_step < N_TIME_STEPS) {
            euler_step(delta_t, N_BODIES, X);
        }
    }

    return 0;
}
