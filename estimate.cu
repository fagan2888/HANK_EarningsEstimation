//#include <sys/time.h>
#include "helper_cuda.h"
#include "newuoa_h.h"
#ifndef TESTING
#include <curand_kernel.h>
#endif

const double dt = .25; // time step in quarters
const int Tburn = 100/dt+1, Tsim = Tburn+20/dt+1, // only need 20 quarters
		Tann = (Tsim-Tburn)*dt/4, Yper = 4/dt;

// Thread block size
#define THREAD_N 32//128

__device__ double4 reduce_sum(double4 in, int n) {
	extern __shared__ double4 sdata[];

	// Perform first level of reduction:
	// - Write to shared memory
	int ltid = threadIdx.x;

	sdata[ltid] = in;
	__syncthreads();

	// Do reduction in shared mem
	for (int s = blockDim.x / 2 ; s > 0 ; s >>= 1) {
		if (ltid < s) {
			double d = sdata[ltid + s].x - sdata[ltid].x, dn = d / 2, dn2 = dn * dn, d2 = d * dn;
			sdata[ltid].w += sdata[ltid + s].w + d2 * dn2 * n + 6 * dn2 * (sdata[ltid].y + sdata[ltid + s].y) - 4 * dn * (sdata[ltid].z - sdata[ltid + s].z);
			sdata[ltid].z += sdata[ltid + s].z - 3 * dn * (sdata[ltid].y - sdata[ltid + s].y);
			sdata[ltid].y += sdata[ltid + s].y + d2 * n;
			sdata[ltid].x += dn;
			n <<= 1;
		}
		__syncthreads();
	}

	return sdata[0];
}

__device__ double4 reduce_fractions(double4 in) {
	extern __shared__ double4 sdata[];

	// Perform first level of reduction:
	// - Write to shared memory
	int ltid = threadIdx.x;

	sdata[ltid] = in;
	__syncthreads();

	// Do reduction in shared mem
	for (int s = blockDim.x / 2 ; s > 0 ; s >>= 1) {
		if (ltid < s) {
			sdata[ltid].x += (sdata[ltid + s].x - sdata[ltid].x) / 2;
			sdata[ltid].y += (sdata[ltid + s].y - sdata[ltid].y) / 2;
			sdata[ltid].z += (sdata[ltid + s].z - sdata[ltid].z) / 2;
			sdata[ltid].w += (sdata[ltid + s].w - sdata[ltid].w) / 2;
		}
		__syncthreads();
	}

	return sdata[0];
}
__device__ inline void computeMoments(double4 *m, double x, int n) {
	double d, d2, dn, dn2;

	d = x - m->x;
	dn = d / (n + 1);
	dn2 = dn * dn;
	d2 = d * dn * n;
	m->w += d2 * dn2 * (n*n - n + 1) + 6 * dn2 * m->y - 4 * dn * m->z;
	m->z += d2 * dn * (n - 1) - 3 * dn * m->y;
	m->y += d2;
	m->x += dn;
}

__device__ inline void computeFractions(double4 *m, double x, int n) {
	m->x += ((x < 0.05) - m->x) / (n + 1);
	m->y += ((x < 0.1) - m->y) / (n + 1);
	m->z += ((x < 0.2) - m->z) / (n + 1);
	m->w += ((x < 0.5) - m->w) / (n + 1);
}

// Simulation kernel
__launch_bounds__(1024)
__global__ void simulate(
#ifndef TESTING
curandState *const rngStates1, curandStatePhilox4_32_10 *const rngStates2,
#else
const double2* d_jumprand, const double2* d_rand,
#endif
	double4* moments, const int nsim, const double2 lambda, const double2 sigma, const double2 delta) {

	// Determine thread ID
	int bid = blockIdx.x;
	int tid = threadIdx.x + blockIdx.x * blockDim.x;
	int step = gridDim.x * blockDim.x; 
	double4 m[4] = { make_double4(0,0,0,0) };

#ifndef TESTING
	// Initialise the RNG
	curandState state1 = rngStates1[tid];
	curandStatePhilox4_32_10 state2 = rngStates2[tid];
#endif

	for (int i = tid; i < nsim; i += step) {
#ifndef TESTING
		// draw initial from normal distribution with same mean and variance
		double2 z = curand_normal2_double(&state1);
#else
		double2 z = d_rand[i*Tsim];
#endif
		z.x = sigma.x/sqrt(1+2*delta.x/lambda.x)*z.x;
		z.y = sigma.y/sqrt(1+2*delta.y/lambda.y)*z.y;

		// simulate income path in dt increments
		double zann[Tann] = { 0 };
		for (int t=1; t<Tsim-1; t++) {
#ifndef TESTING
			// Generate pseudo-random numbers
			double2 rand = curand_normal2_double(&state1);
			double2 jumprand = curand_uniform2_double(&state2);
#else
			int j = i*Tsim+t;
			double2 rand = d_rand[j];
			double2 jumprand = d_jumprand[j-1];
#endif
			z.x = jumprand.x > 1-dt*lambda.x ? sigma.x*rand.x : (1-dt*delta.x) * z.x;
			z.y = jumprand.y > 1-dt*lambda.y ? sigma.y*rand.y : (1-dt*delta.y) * z.y;
			if (t>=Tburn) zann[(t-Tburn)/Yper] += exp(z.x + z.y); // aggregate to annual income
		}

//if (tid == 0) printf("%d/%d% d/%d: %.15g %.15g %.15g\n",threadIdx.x,blockDim.x,blockIdx.x,gridDim.x,log(zann[0]),log(zann[1]/zann[0]),log(zann[4]/zann[0]));
		// Compute central moments
		computeMoments(&m[0],log(zann[0]),i/step); // logs
		computeMoments(&m[1],log(zann[1]/zann[0]),i/step); // 1 year log changes
		computeMoments(&m[2],log(zann[4]/zann[0]),i/step); // 5 year log changes
		computeFractions(&m[3],abs(log(zann[1]/zann[0])),i/step); // fraction 1 year log changes in ranges
	}
//if (blockIdx.x==0) printf("%03d: %.15g %.15g %.15g %.15g %.15g %.15g %.15g %.15g %.15g %.15g %.15g %.15g\n",tid,m[0].x,m[0].y,m[0].z,m[0].w,m[1].x,m[1].y,m[1].z,m[1].w,m[2].x,m[2].y,m[2].z,m[2].w);

#ifndef TESTING
	// Copy RNG state back to global memory
	rngStates1[tid] = state1;
	rngStates2[tid] = state2;
#endif

	// Reduce within the block
	m[0] = reduce_sum(m[0],nsim/step);
	m[1] = reduce_sum(m[1],nsim/step);
	m[2] = reduce_sum(m[2],nsim/step);
	m[3] = reduce_fractions(m[3]);

	// Store the result
	if (threadIdx.x == 0) {
		moments[bid*4] = m[0];
		moments[bid*4+1] = m[1];
		moments[bid*4+2] = m[2];
		moments[bid*4+3] = m[3];
//printf("%03d: %.15g %.15g %.15g %.15g %.15g %.15g %.15g %.15g %.15g %.15g %.15g %.15g\n",tid,m[0].x,m[0].y,m[0].z,m[0].w,m[1].x,m[1].y,m[1].z,m[1].w,m[2].x,m[2].y,m[2].z,m[2].w);
	}
}

#ifndef TESTING
// RNG init kernel
__global__ void initRNG(curandState *const rngStates1, curandStatePhilox4_32_10 *const rngStates2) {
	// Determine thread ID
	int tid = blockIdx.x * blockDim.x + threadIdx.x;
	const int seed = (int)clock64();
	// Initialise the RNG
	curand_init(seed, tid, 0, &rngStates1[tid]);
	curand_init(seed, tid, 0, &rngStates2[tid]);
}
#else
double2* read_data(int rows, int cols, const char* fname) {
	double2* h_data = (double2*) malloc(rows*cols*sizeof(double2));
	FILE *f;
	f = fopen(fname,"r");
	if (f == NULL) {
		printf("Error opening input file!\n");
		exit(EXIT_FAILURE);
	}
	for (int i=0; i<rows; i++)
		for (int j=0; j<cols*2; j++) {
			double num;
			fscanf(f,"%lf",&num);
			if (j<cols) h_data[i*cols+j].x = num;
			else h_data[(i-1)*cols+j].y = num;
		}
	fclose(f);
	return h_data;
}
#endif

typedef struct PlanType
{
	// Device ID for multi-GPU version
	int device;
	// Simulation path count for this plan
	int nsim;
	int gridSize;
	// Stream handle and event object for this plan
	cudaStream_t stream;
	cudaEvent_t event;
	// Device- and host-side intermediate results
	double4 *d_moments;
	double4 *h_moments;
#ifndef TESTING
	// Random number generator states
	curandState *d_rngStates1;
	curandStatePhilox4_32_10 *d_rngStates2;
#else
	double2 *d_jumprand;
	double2 *d_rand;
#endif
} PlanType;

typedef struct UserParamsType {
	int nPlans;
	PlanType *plan;
	// Host-side target moments and result destination
	double4 targets[4];
	double4 moments[4];
} UserParamsType;

int timeval_subtract (double *result, struct timeval *x, struct timeval *y)
{
	struct timeval result0;

	/* Perform the carry for the later subtraction by updating y. */
	if (x->tv_usec < y->tv_usec)
	{
		int nsec = (y->tv_usec - x->tv_usec) / 1000000 + 1;
		y->tv_usec -= 1000000 * nsec;
		y->tv_sec += nsec;
	}
	if (x->tv_usec - y->tv_usec > 1000000)
	{
		int nsec = (y->tv_usec - x->tv_usec) / 1000000;
		y->tv_usec += 1000000 * nsec;
		y->tv_sec -= nsec;
	}

	/* Compute the time remaining to wait.
	tv_usec is certainly positive. */
	result0.tv_sec = x->tv_sec - y->tv_sec;
	result0.tv_usec = x->tv_usec - y->tv_usec;
	*result = ((double)result0.tv_usec)/1e6 + (double)result0.tv_sec;

	/* Return 1 if result is negative. */
	return x->tv_sec < y->tv_sec;
}

static void dfovec(const long int nx, const long int mv, const double *x, double *v_err, const void * userParams) {
	UserParamsType *pUserParams = (UserParamsType *) userParams;
	PlanType *plan = pUserParams->plan;
	int nPlans = pUserParams->nPlans;
	double4 *targets = pUserParams->targets;
	double4 *moments = pUserParams->moments;

	for (int i=0; i<nPlans; i++)
	{
		int nsim = plan[i].nsim;
		int gridSize = plan[i].gridSize;
		double4 *d_moments = plan[i].d_moments;
		double4 *h_moments = plan[i].h_moments;
#ifndef TESTING
		curandState *d_rngStates1 = plan[i].d_rngStates1;
		curandStatePhilox4_32_10 *d_rngStates2 = plan[i].d_rngStates2;
#else
		double2 *d_jumprand = plan[i].d_jumprand;
		double2 *d_rand = plan[i].d_rand;
#endif
		if (nx != 6 || mv != 8) {
			fprintf(stderr,"*** dfovec incorrectly called with n=%d and mv=%d\n",nx,mv);
			return;
		}

		double2 lambda = make_double2(2/(1+exp(-x[0])), 2/(1+exp(-x[1])));
		double2 sigma  = make_double2(2/(1+exp(-x[2])), 2/(1+exp(-x[3])));
		double2 delta  = make_double2(1/(1+exp(-x[4])), 1/(1+exp(-x[5])));

		// Simulate the process and compute moments
		checkCudaErrors(cudaSetDevice(plan[i].device));
		simulate<<<gridSize, THREAD_N, THREAD_N*sizeof(double4), plan[i].stream>>>(
#ifndef TESTING
d_rngStates1, d_rngStates2,
#else
d_jumprand, d_rand, 
#endif
d_moments, nsim, lambda, sigma, delta);

		getLastCudaError("Failed to launch simulate kernel\n");

		// Copy partial results to host
		checkCudaErrors(cudaMemcpyAsync(h_moments, d_moments, gridSize*4*sizeof(double4), cudaMemcpyDeviceToHost, plan[i].stream));

		checkCudaErrors(cudaEventRecord(plan[i].event, plan[i].stream));
	}
	for (int i=0; i<nPlans; i++) {
		checkCudaErrors(cudaSetDevice(plan[i].device));
		cudaEventSynchronize(plan[i].event);
	}
	// Complete reduction on host
	for (int j=0; j<3; j++) {
		double	m1 = 0, m2 = 0, m3 = 0, m4 = 0;
		int nsim = 0;
		for (int i=0; i<nPlans; i++)
		{
			int gridSize = plan[i].gridSize;
			int nb = plan[i].nsim / gridSize;
			for (int n=0; n<gridSize; n++) {
				double4 m = plan[i].h_moments[n*4+j];
				double d = m.x - m1, dn = d / (nsim + nb), dn2 = dn * dn, d2 = d * dn * nb * nsim;
				m4 += m.w + d2 * dn2 * (nsim*nsim - nsim*nb + nb*nb) + 6 * dn2 * (nsim*nsim*m.y + nb*nb*m2) + 4 * dn * (nsim*m.z - nb*m3);
				m3 += m.z + d2 * dn * (nsim - nb) + 3 * dn * (nsim*m.y - nb*m2);
				m2 += m.y + d2;
				m1 += dn * nb;
				nsim += nb;
//printf("++ %.15g %.15g %.15g %.15g\n",m.x,m.y,m.z,m.w);
			}
//printf("%.15g %.15g %.15g %.15g\n",m1,m2,m3,m4);
		}
		// Compute standardised moments
		m2 /= nsim;
		m3 /= nsim*m2*sqrt(m2);
		m4 /= nsim*m2*m2;
		moments[j].x = m1; //mean
		moments[j].y = m2; // variance
		moments[j].z = m3; // skewness
		moments[j].w = m4; // kurtosis
//printf("%.15g %.15g %.15g %.15g\n",moments[j].x,moments[j].y,moments[j].z,moments[j].w);
	}
	// Compute fraction of dy1 less than 5%, 10%, 20% and 50%
	moments[3] = make_double4(0.0,0.0,0.0,0.0);
	int nsim = 0;
	for (int i=0; i<nPlans; i++)
	{
		int gridSize = plan[i].gridSize;
		int nb = plan[i].nsim / gridSize;
		for (int n=0; n<gridSize; n++) {
			double4 m = plan[i].h_moments[n*4+3];
			moments[3].x += (m.x - moments[3].x) * nb / (nsim + nb);
			moments[3].y += (m.y - moments[3].y) * nb / (nsim + nb);
			moments[3].z += (m.z - moments[3].z) * nb / (nsim + nb);
			moments[3].w += (m.w - moments[3].w) * nb / (nsim + nb);
			nsim += nb;
		}
	}
//printf("%.15g %.15g %.15g %.15g\n",moments[3].x,moments[3].y,moments[3].z,moments[3].w);

//	printf("%.15g\t%.15g\t%.15g\t%.15g\t%.15g\t%.15g\t%.15g\n",obj,lambda.x,lambda.y,sigma.x,sigma.y,delta.x,delta.y);
	v_err[0] = moments[0].y/targets[0].y-1;
	v_err[1] = moments[1].y/targets[1].y-1;
	v_err[2] = moments[1].w/targets[1].w-1;
	v_err[3] = moments[2].y/targets[2].y-1;
	v_err[4] = moments[2].w/targets[2].w-1;
	v_err[5] = moments[3].y/targets[3].y-1;
	v_err[6] = moments[3].z/targets[3].z-1;
	v_err[7] = moments[3].w/targets[3].w-1;
	v_err[2] *= sqrt(0.5);
	v_err[4] *= sqrt(0.5);
}

int main() {
#ifndef TESTING
	long NSIM = 1<<20;
#else
	long NSIM = 4992;
	double2* h_jumprand = read_data(NSIM,Tsim,"../../earnings_estimation_output/yjumprand.txt");
	double2* h_rand = read_data(NSIM,Tsim,"../../earnings_estimation_output/yrand.txt");
	int gpuBase = 0;
#endif

	// Get number of available devices
	int GPU_N = 0;
	checkCudaErrors(cudaGetDeviceCount(&GPU_N));
	if (!GPU_N)
	{
		fprintf(stderr,"There are no CUDA devices.\n");
		exit(EXIT_FAILURE);
	}
	printf("CUDA-capable device count: %i\n", GPU_N);
	if ((NSIM/GPU_N) % THREAD_N) 
	{
		fprintf(stderr,"The number of simulation paths per GPU must be a multiple of block size.\n");
		exit(EXIT_FAILURE);
	}

	UserParamsType userParams;
	userParams.nPlans = GPU_N;
	userParams.plan = new PlanType[GPU_N];
	for (int device=0; device<GPU_N; device++)
	{
		// Attach to GPU
		checkCudaErrors(cudaSetDevice(device));
		// Get device properties
		struct cudaDeviceProp deviceProperties;
		checkCudaErrors(cudaGetDeviceProperties(&deviceProperties, device));
		// Check precision is valid
		if (deviceProperties.major < 1 || (deviceProperties.major == 1 && deviceProperties.minor < 3)) {
			printf("Device %d does not have double precision support.\n", device);
			exit(EXIT_FAILURE);
		}

		PlanType *p = &userParams.plan[device];
		p->device = device;

		// Initialize stream handle and event object for the current device
		checkCudaErrors(cudaStreamCreate(&p->stream));
		checkCudaErrors(cudaEventCreate(&p->event));

		// Divide the work between GPUs equally
		p->nsim = NSIM / GPU_N;
		if (device < (NSIM % GPU_N)) p->nsim++;

		p->gridSize = p->nsim / THREAD_N;
		// Aim to launch around ten to twenty times as many blocks as there
		// are multiprocessors on the target device.
		// read more on grid-stride loops: https://devblogs.nvidia.com/cuda-pro-tip-write-flexible-kernels-grid-stride-loops/
		while (p->gridSize > 20 * deviceProperties.multiProcessorCount) p->gridSize >>= 1;

		printf("GPU Device #%i: %s\n", p->device, deviceProperties.name);
		printf("Simulation paths: %i\n", p->nsim);
		printf("Grid size: %i\n", p->gridSize);

		// Allocate intermediate memory for MC results
		// Each thread block will produce four double4 results
		p->h_moments = (double4*)malloc(p->gridSize*4*sizeof(double4));
		checkCudaErrors(cudaMalloc((void **)&p->d_moments, p->gridSize*4*sizeof(double4)));

#ifndef TESTING
		// Allocate memory for RNG states
		checkCudaErrors(cudaMalloc(&p->d_rngStates1, p->gridSize * THREAD_N * sizeof(curandState)));
		checkCudaErrors(cudaMalloc(&p->d_rngStates2, p->gridSize * THREAD_N * sizeof(curandStatePhilox4_32_10)));
		// Initialise RNG states
		initRNG<<<p->gridSize, THREAD_N>>>(p->d_rngStates1, p->d_rngStates2);
#else
		checkCudaErrors(cudaMalloc(&p->d_jumprand, p->nsim*Tsim*sizeof(double2)));
		checkCudaErrors(cudaMemcpy(p->d_jumprand, &h_jumprand[gpuBase], p->nsim*Tsim*sizeof(double2), cudaMemcpyHostToDevice));
		checkCudaErrors(cudaMalloc(&p->d_rand, p->nsim*Tsim*sizeof(double2)));
		checkCudaErrors(cudaMemcpy(p->d_rand, &h_rand[gpuBase], p->nsim*Tsim*sizeof(double2), cudaMemcpyHostToDevice));
		gpuBase += Tsim*p->nsim;
#endif
		checkCudaErrors(cudaDeviceSynchronize());
	}
#ifdef TESTING
	free(h_jumprand);
	free(h_rand);
#endif

	// Target moments for USA: 0.7,0.23,17.8,0.46,11.55,0.54,0.71,0.86
	// Target moments for Canada: 0.760,0.217,13.377,0.437,8.782,0.51,0.68,0.85
	userParams.targets[0] = make_double4(NAN, 0.760, NAN, NAN); // LogY: Mean,Var,Skew,Kurt
	userParams.targets[1] = make_double4(NAN, 0.217, NAN, 13.377); // D1LogY: Mean,Var,Skew,Kurt
	userParams.targets[2] = make_double4(NAN, 0.437, NAN, 8.782); // D5LogY: Mean,Var,Skew,Kurt
	userParams.targets[3] = make_double4(NAN, 0.51, 0.68, 0.85); // FracD1: <5%,<10%,<20%,<50%

	long int n=6, mv=8, npt=2*n+1, maxfun=500*(n+1), iprint=3;
	double v_err[8], rhobeg=5.0, rhoend=1e-4, w[543];
	double xmax[6] = {2,2,2,2,1,1}, xmin[6] = {0};
//	double x[6] = {0.0972241396763905,  0.014312611368279, 1.60304896242711, 0.892309166034993, 0.947420941274568,  0.00117609031021279};
	double x[6] = {.08,.007,1.6,1.6,.7,.01};

	for (int i=0; i<6; i++) x[i] = -log(xmax[i]/(x[i]-xmin[i])-1); // invlogistic
	newuoa_h(n, npt, dfovec, &userParams, x, rhobeg, rhoend, iprint, maxfun, w, mv);

//	struct timeval tdr0;
//	gettimeofday (&tdr0, NULL);

	dfovec(n,mv,x,v_err,&userParams);
	double obj = 0;
	for (int i=0; i<mv; i++)
		obj += v_err[i]*v_err[i];
//	struct timeval tdr1;
//	gettimeofday(&tdr1, NULL);
//	double time;
//	timeval_subtract(&time,&tdr1,&tdr0);
	
	for (int i=0; i<6; i++)  x[i] = xmin[i]+xmax[i]/(1+exp(-x[i])); // logistic
//	printf("\nTotal time (sec.): %f\n", time);
	printf("\nFinal objective function value: %.15g\n",obj);//sqrt(obj*2/7));
	printf("\nThe returned solution is:\n");
	printf(" lambda: %.15g  %.15g\n",x[0],x[1]);
	printf(" sigma:  %.15g  %.15g\n",x[2],x[3]);
	printf(" delta:  %.15g  %.15g\n",x[4],x[5]);
	printf("\n Moment:      Target:\tModel:\n");
	printf(" MeanLogY     %.15g\t%.15g\n",userParams.targets[0].x,userParams.moments[0].x);
	printf(" VarLogY      %.15g\t%.15g\n",userParams.targets[0].y,userParams.moments[0].y);
	printf(" SkewLogY     %.15g\t%.15g\n",userParams.targets[0].z,userParams.moments[0].z);
	printf(" KurtLogY     %.15g\t%.15g\n",userParams.targets[0].w,userParams.moments[0].w);
	printf(" MeanD1LogY   %.15g\t%.15g\n",userParams.targets[1].x,userParams.moments[1].x);
	printf(" VarD1LogY    %.15g\t%.15g\n",userParams.targets[1].y,userParams.moments[1].y);
	printf(" SkewD1LogY   %.15g\t%.15g\n",userParams.targets[1].z,userParams.moments[1].z);
	printf(" KurtD1LogY   %.15g\t%.15g\n",userParams.targets[1].w,userParams.moments[1].w);
	printf(" MeanD5LogY   %.15g\t%.15g\n",userParams.targets[2].x,userParams.moments[2].x);
	printf(" VarD5LogY    %.15g\t%.15g\n",userParams.targets[2].y,userParams.moments[2].y);
	printf(" SkewD5LogY   %.15g\t%.15g\n",userParams.targets[2].z,userParams.moments[2].z);
	printf(" KurtD5LogY   %.15g\t%.15g\n",userParams.targets[2].w,userParams.moments[2].w);
	printf(" FracD1Less5  %.15g\t%.15g\n",userParams.targets[3].x,userParams.moments[3].x);
	printf(" FracD1Less10 %.15g\t%.15g\n",userParams.targets[3].y,userParams.moments[3].y);
	printf(" FracD1Less20 %.15g\t%.15g\n",userParams.targets[3].z,userParams.moments[3].z);
	printf(" FracD1Less50 %.15g\t%.15g\n",userParams.targets[3].w,userParams.moments[3].w);

	// Cleanup
	for (int device=0; device<GPU_N; device++)
	{
		PlanType *p = &userParams.plan[device];
		checkCudaErrors(cudaSetDevice(p->device));
		checkCudaErrors(cudaStreamDestroy(p->stream));
		checkCudaErrors(cudaEventDestroy(p->event));
		free(p->h_moments);
	        cudaFree(p->d_moments);
#ifndef TESTING
		cudaFree(p->d_rngStates1);
		cudaFree(p->d_rngStates2);
#else
        	cudaFree(p->d_jumprand);
	        cudaFree(p->d_rand);
#endif
	}
	return(0);
}

