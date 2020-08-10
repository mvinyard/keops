#pragma once

#include <stdio.h>
#include <iostream>
#include <assert.h>
#include <cuda.h>

#include "core/pack/Pack.h"
#include "core/pack/GetInds.h"
#include "core/pack/GetDims.h"
#include "core/utils/CudaErrorCheck.cu"
#include "core/utils/CudaSizes.h"
#include "core/utils/TypesUtils.h"

// these 3 lines to be removed, used for debug...
//#include <type_traits>
//typedef typename F00::xxxx xxxx;
//static_assert(std::is_same<F00, F0>::value, "not same type");


namespace keops {

template < class FUN, typename TYPE >
struct Chunk_Mode_Constants {

	static const int DIMRED = FUN::DIMRED; // dimension of reduction operation

	typedef typename FUN::DIMSP DIMSP;  // DIMSP is a "vector" of templates giving dimensions of parameters variables
	typedef typename FUN::INDSP INDSP;
	static const int DIMP = DIMSP::SUM;

	static const int DIMOUT = FUN::DIM; // dimension of output variable
	static const int DIMFOUT = FUN::F::DIM; // dimension of output variable

	static const int DIM_ORG = FUN::F::template CHUNKED_FORMULAS<DIMCHUNK>::FIRST::NEXT::FIRST::FIRST;
	static const int NCHUNKS = 1 + (DIM_ORG-1) / DIMCHUNK;
	static const int DIMLASTCHUNK = DIM_ORG - (NCHUNKS-1)*DIMCHUNK;
	static const int NMINARGS = FUN::NMINARGS;

	using FUN_CHUNKED = typename FUN::F::template CHUNKED_FORMULAS<DIMCHUNK>::FIRST::FIRST;
	static const int DIMOUT_CHUNK = FUN_CHUNKED::DIM;
	using VARSI_CHUNKED = typename FUN_CHUNKED::template CHUNKED_VARS<FUN::tagI>;
	using DIMSX_CHUNKED = GetDims<VARSI_CHUNKED>;
	using INDSI_CHUNKED = GetInds<VARSI_CHUNKED>;
	using VARSJ_CHUNKED = typename FUN_CHUNKED::template CHUNKED_VARS<FUN::tagJ>;
	using DIMSY_CHUNKED = GetDims<VARSJ_CHUNKED>;
	using INDSJ_CHUNKED = GetInds<VARSJ_CHUNKED>;

	using FUN_POSTCHUNK  = typename FUN::F::template POST_CHUNK_FORMULA < NMINARGS >;
	using VARSI_POSTCHUNK = typename FUN_POSTCHUNK::template VARS<FUN::tagI>;
	using DIMSX_POSTCHUNK = GetDims<VARSI_POSTCHUNK>;
	using VARSJ_POSTCHUNK = typename FUN_POSTCHUNK::template VARS<FUN::tagJ>;
	using DIMSY_POSTCHUNK = GetDims<VARSJ_POSTCHUNK>;

	using VARSI_NOTCHUNKED = MergePacks < VARSI_POSTCHUNK, typename FUN_CHUNKED::template NOTCHUNKED_VARS<FUN::tagI> >;
	using INDSI_NOTCHUNKED = GetInds<VARSI_NOTCHUNKED>;
	using DIMSX_NOTCHUNKED = GetDims<VARSI_NOTCHUNKED>;
	static const int DIMX_NOTCHUNKED = DIMSX_NOTCHUNKED::SUM;

	using VARSJ_NOTCHUNKED = MergePacks < VARSJ_POSTCHUNK, typename FUN_CHUNKED::template NOTCHUNKED_VARS<FUN::tagJ> >;
	using INDSJ_NOTCHUNKED = GetInds<VARSJ_NOTCHUNKED>;
	using DIMSY_NOTCHUNKED = GetDims<VARSJ_NOTCHUNKED>;
	static const int DIMY_NOTCHUNKED = DIMSY_NOTCHUNKED::SUM;

	using FUN_LASTCHUNKED = typename FUN::F::template CHUNKED_FORMULAS<DIMLASTCHUNK>::FIRST::FIRST;
	using VARSI_LASTCHUNKED = typename FUN_LASTCHUNKED::template CHUNKED_VARS<FUN::tagI>;
	using DIMSX_LASTCHUNKED = GetDims<VARSI_LASTCHUNKED>;
	using VARSJ_LASTCHUNKED = typename FUN_LASTCHUNKED::template CHUNKED_VARS<FUN::tagJ>;
	using DIMSY_LASTCHUNKED = GetDims<VARSJ_LASTCHUNKED>;

	using VARSI = ConcatPacks < VARSI_NOTCHUNKED, VARSI_CHUNKED >;
	using DIMSX = GetDims<VARSI>;
	using INDSI = GetInds<VARSI>;
	static const int DIMX = DIMSX::SUM;

	using VARSJ = ConcatPacks < VARSJ_NOTCHUNKED, VARSJ_CHUNKED >;
	using DIMSY = GetDims<VARSJ>;
	using INDSJ = GetInds<VARSJ>;
	static const int DIMY = DIMSY::SUM;

	using INDS = ConcatPacks < ConcatPacks < INDSI, INDSJ >, INDSP >;

	using VARSI_LAST = ConcatPacks < VARSI_NOTCHUNKED, VARSI_LASTCHUNKED >;
	using DIMSX_LAST = GetDims<VARSI_LAST>;

	using VARSJ_LAST = ConcatPacks < VARSJ_NOTCHUNKED, VARSJ_LASTCHUNKED >;
	using DIMSY_LAST = GetDims<VARSJ_LAST>;
};

template < class FUN, class FUN_CHUNKED_CURR, int DIMCHUNK_CURR, typename TYPE >
__device__ void do_chunk_sub(TYPE *acc, int tile, int i, int j, int jstart, int chunk, int nx, int ny, 
			TYPE **args, TYPE *fout, TYPE *xi, TYPE *yj, TYPE *param_loc) {
	
	using CHK = Chunk_Mode_Constants<FUN,TYPE>;

	TYPE fout_tmp_chunk[CHK::FUN_CHUNKED::DIM];
	
	if (i < nx) 
		load_chunks < typename CHK::INDSI_CHUNKED, DIMCHUNK, DIMCHUNK_CURR, CHK::DIM_ORG >(i, chunk, xi + CHK::DIMX_NOTCHUNKED, args);
	__syncthreads();
	
	if (j < ny) // we load yj from device global memory only if j<ny
		load_chunks < typename CHK::INDSJ_CHUNKED, DIMCHUNK, DIMCHUNK_CURR, CHK::DIM_ORG > (j, chunk, yj + threadIdx.x * CHK::DIMY + CHK::DIMY_NOTCHUNKED, args);
	__syncthreads();
	
	if (i < nx) { // we compute only if needed
		TYPE * yjrel = yj; // Loop on the columns of the current block.
		for (int jrel = 0; (jrel < blockDim.x) && (jrel < ny - jstart); jrel++, yjrel += CHK::DIMY) {
			TYPE *foutj = fout+jrel*CHK::FUN_CHUNKED::DIM;
			call < CHK::DIMSX, CHK::DIMSY, CHK::DIMSP > 
				(FUN_CHUNKED_CURR::template EvalFun<CHK::INDS>(), fout_tmp_chunk, xi, yjrel, param_loc);
			CHK::FUN_CHUNKED::acc_chunk(foutj, fout_tmp_chunk);
		}
	}
}


template<typename TYPE, class FUN>
__global__ void GpuConv1DOnDevice_Chunks(FUN fun, int nx, int ny, TYPE *out, TYPE **args) {

	using CHK = Chunk_Mode_Constants<FUN,TYPE>;

	// get the index of the current thread
	int i = blockIdx.x * blockDim.x + threadIdx.x;
	
	// declare shared mem
	extern __shared__ TYPE yj[];

	// load parameter(s)
	TYPE param_loc[CHK::DIMP < 1 ? 1 : CHK::DIMP];
	load<CHK::DIMSP,CHK::INDSP>(0, param_loc, args); // load parameters variables from global memory to local thread memory

	__TYPEACC__ acc[CHK::DIMRED];

#if SUM_SCHEME == BLOCK_SUM
    // additional tmp vector to store intermediate results from each block
    TYPE tmp[CHK::DIMRED];
#elif SUM_SCHEME == KAHAN_SCHEME
    // additional tmp vector to accumulate errors
    static const int DIM_KAHAN = FUN::template KahanScheme<__TYPEACC__,TYPE>::DIMACC;
    TYPE tmp[DIM_KAHAN];
#endif

	if (i < nx) {
		typename FUN::template InitializeReduction<__TYPEACC__, TYPE >()(acc); // acc = 0
#if SUM_SCHEME == KAHAN_SCHEME
		VectAssign<DIM_KAHAN>(tmp,0.0f);
#endif		
	}




	
	TYPE xi[CHK::DIMX];

	TYPE fout_chunk[CUDA_BLOCK_SIZE_CHUNKS*CHK::DIMOUT_CHUNK];
	
	if (i < nx)
		load < CHK::DIMSX_NOTCHUNKED, CHK::INDSI_NOTCHUNKED > (i, xi, args); // load xi variables from global memory to local thread memory
	__syncthreads();

	for (int jstart = 0, tile = 0; jstart < ny; jstart += blockDim.x, tile++) {

		// get the current column
		int j = tile * blockDim.x + threadIdx.x;
	
		if (j < ny) 
			load<CHK::DIMSY_NOTCHUNKED, CHK::INDSJ_NOTCHUNKED>(j, yj + threadIdx.x * CHK::DIMY, args);
		__syncthreads();

		if (i < nx) { // we compute only if needed
			for (int jrel = 0; (jrel < blockDim.x) && (jrel < ny - jstart); jrel++)
				CHK::FUN_CHUNKED::initacc_chunk(fout_chunk+jrel*CHK::DIMOUT_CHUNK);
#if SUM_SCHEME == BLOCK_SUM
			typename FUN::template InitializeReduction<TYPE,TYPE>()(tmp); // tmp = 0
#endif
		}
		__syncthreads();
	
		// looping on chunks (except the last)
		#pragma unroll
		for (int chunk=0; chunk<CHK::NCHUNKS-1; chunk++)
			do_chunk_sub < FUN, CHK::FUN_CHUNKED, DIMCHUNK >
				(acc, tile, i, j, jstart, chunk, nx, ny, args, fout_chunk, xi, yj, param_loc);	
		// last chunk
		do_chunk_sub < FUN, CHK::FUN_LASTCHUNKED, CHK::DIMLASTCHUNK >
			(acc, tile, i, j, jstart, CHK::NCHUNKS-1, nx, ny, args, fout_chunk, xi, yj, param_loc);





		if (i < nx) { 
			TYPE * yjrel = yj; // Loop on the columns of the current block.
			for (int jrel = 0; (jrel < blockDim.x) && (jrel < ny - jstart); jrel++, yjrel += CHK::DIMY) {
#if SUM_SCHEME != KAHAN_SCHEME
				int ind = jrel + tile * blockDim.x;
#endif
				TYPE *foutj = fout_chunk + jrel*CHK::DIMOUT_CHUNK;
				TYPE fout_tmp[CHK::DIMFOUT];
				call<CHK::DIMSX, CHK::DIMSY, CHK::DIMSP, pack<CHK::DIMOUT_CHUNK> >
						(typename CHK::FUN_POSTCHUNK::template EvalFun<ConcatPacks<typename CHK::INDS,pack<FUN::NMINARGS>>>(), 
						fout_tmp,xi, yjrel, param_loc, foutj);
#if SUM_SCHEME == BLOCK_SUM
#if USE_HALF
        			typename FUN::template ReducePairShort<TYPE,TYPE>()(tmp, fout_tmp, __floats2half2_rn(2*ind,2*ind+1));     // tmp += fout_tmp
#else
				typename FUN::template ReducePairShort<TYPE,TYPE>()(tmp, fout_tmp, ind);     // tmp += fout_tmp
#endif
#elif SUM_SCHEME == KAHAN_SCHEME
				typename FUN::template KahanScheme<__TYPEACC__,TYPE>()(acc, fout_tmp, tmp);     
#else
#if USE_HALF
				typename FUN::template ReducePairShort<__TYPEACC__,TYPE>()(acc, fout_tmp, __floats2half2_rn(2*ind,2*ind+1));     // acc += fout_tmp
#else
				typename FUN::template ReducePairShort<__TYPEACC__,TYPE>()(acc, fout_tmp, ind);     // acc += fout_tmp
#endif
#endif
			}
#if SUM_SCHEME == BLOCK_SUM
			typename FUN::template ReducePair<__TYPEACC__,TYPE>()(acc, tmp);     // acc += tmp
#endif
		}
	}
	__syncthreads();

	if (i < nx) 
		typename FUN::template FinalizeOutput<__TYPEACC__,TYPE>()(acc, out + i * CHK::DIMOUT, i);
	__syncthreads();
}


template<typename TYPE, class FUN>
__global__ void GpuConv1DOnDevice(FUN fun, int nx, int ny, TYPE *out, TYPE **args) {

  // get the index of the current thread
  int i = blockIdx.x * blockDim.x + threadIdx.x;

  // declare shared mem
  extern __shared__ TYPE yj[];

  // get templated dimensions :
  typedef typename FUN::DIMSX DIMSX;  // DIMSX is a "vector" of templates giving dimensions of xi variables
  typedef typename FUN::DIMSY DIMSY;  // DIMSY is a "vector" of templates giving dimensions of yj variables
  typedef typename FUN::DIMSP DIMSP;  // DIMSP is a "vector" of templates giving dimensions of parameters variables
    typedef typename FUN::INDSI INDSI;
    typedef typename FUN::INDSJ INDSJ;
    typedef typename FUN::INDSP INDSP;
  const int DIMX = DIMSX::SUM;        // DIMX  is sum of dimensions for xi variables
  const int DIMY = DIMSY::SUM;        // DIMY  is sum of dimensions for yj variables
  const int DIMP = DIMSP::SUM;        // DIMP  is sum of dimensions for parameters variables
  const int DIMOUT = FUN::DIM; // dimension of output variable
  const int DIMRED = FUN::DIMRED; // dimension of reduction operation
  const int DIMFOUT = FUN::F::DIM;     // DIMFOUT is dimension of output variable of inner function

  // load parameter(s)
  TYPE param_loc[DIMP < 1 ? 1 : DIMP];
  load<DIMSP, INDSP>(0, param_loc, args); // load parameters variables from global memory to local thread memory

  TYPE fout[DIMFOUT];
  // get the value of variable (index with i)
  TYPE xi[DIMX < 1 ? 1 : DIMX];
  __TYPEACC__ acc[DIMRED];
#if SUM_SCHEME == BLOCK_SUM
    // additional tmp vector to store intermediate results from each block
    TYPE tmp[DIMRED];
#elif SUM_SCHEME == KAHAN_SCHEME
    // additional tmp vector to accumulate errors
    const int DIM_KAHAN = FUN::template KahanScheme<__TYPEACC__,TYPE>::DIMACC;
    TYPE tmp[DIM_KAHAN];
#endif
  if (i < nx) {
    typename FUN::template InitializeReduction<__TYPEACC__, TYPE >()(acc); // acc = 0
#if SUM_SCHEME == KAHAN_SCHEME
    VectAssign<DIM_KAHAN>(tmp,0.0f);
#endif
    load<DIMSX, INDSI>(i, xi, args); // load xi variables from global memory to local thread memory
  }

  for (int jstart = 0, tile = 0; jstart < ny; jstart += blockDim.x, tile++) {

    // get the current column
    int j = tile * blockDim.x + threadIdx.x;

    if (j < ny) { // we load yj from device global memory only if j<ny
      load<DIMSY,INDSJ>(j, yj + threadIdx.x * DIMY, args); // load yj variables from global memory to shared memory
    }
    __syncthreads();

    if (i < nx) { // we compute x1i only if needed
      TYPE * yjrel = yj; // Loop on the columns of the current block.
#if SUM_SCHEME == BLOCK_SUM
      typename FUN::template InitializeReduction<TYPE,TYPE>()(tmp); // tmp = 0
#endif
      for (int jrel = 0; (jrel < blockDim.x) && (jrel < ny - jstart); jrel++, yjrel += DIMY) {
        call<DIMSX, DIMSY, DIMSP>(fun,
				  fout,
                                  xi,
                                  yjrel,
                                  param_loc); // Call the function, which outputs results in fout
#if SUM_SCHEME == BLOCK_SUM
#if USE_HALF
        int ind = jrel + tile * blockDim.x;
        typename FUN::template ReducePairShort<TYPE,TYPE>()(tmp, fout, __floats2half2_rn(2*ind,2*ind+1));     // tmp += fout
#else
        typename FUN::template ReducePairShort<TYPE,TYPE>()(tmp, fout, jrel + tile * blockDim.x);     // tmp += fout
#endif
#elif SUM_SCHEME == KAHAN_SCHEME
        typename FUN::template KahanScheme<__TYPEACC__,TYPE>()(acc, fout, tmp);     
#else
#if USE_HALF
        int ind = jrel + tile * blockDim.x;
        typename FUN::template ReducePairShort<__TYPEACC__,TYPE>()(acc, fout, __floats2half2_rn(2*ind,2*ind+1));     // acc += fout
#else
	typename FUN::template ReducePairShort<__TYPEACC__,TYPE>()(acc, fout, jrel + tile * blockDim.x);     // acc += fout
#endif
#endif
      }
#if SUM_SCHEME == BLOCK_SUM
      typename FUN::template ReducePair<__TYPEACC__,TYPE>()(acc, tmp);     // acc += tmp
#endif
    }
    __syncthreads();
  }
  if (i < nx) {
    typename FUN::template FinalizeOutput<__TYPEACC__,TYPE>()(acc, out + i * DIMOUT, i);
  }

}







struct GpuConv1D_FromHost {

  template<typename TYPE, class FUN>
  static int Eval_(FUN fun, int nx, int ny, TYPE *out, TYPE **args_h) {

    typedef typename FUN::DIMSX DIMSX;
    typedef typename FUN::DIMSY DIMSY;
    typedef typename FUN::DIMSP DIMSP;
    typedef typename FUN::INDSI INDSI;
    typedef typename FUN::INDSJ INDSJ;
    typedef typename FUN::INDSP INDSP;
    const int DIMX = DIMSX::SUM;
    const int DIMY = DIMSY::SUM;
    const int DIMP = DIMSP::SUM;
    const int DIMOUT = FUN::DIM; // dimension of output variable
    const int SIZEI = DIMSX::SIZE;
    const int SIZEJ = DIMSY::SIZE;
    const int SIZEP = DIMSP::SIZE;
    static const int NMINARGS = FUN::NMINARGS;

    // pointer to device output array
    TYPE *out_d;

    // array of pointers to device input arrays
    TYPE **args_d;

    void *p_data;
    // single cudaMalloc
    CudaSafeCall(cudaMalloc(&p_data,
                            sizeof(TYPE *) * NMINARGS
                                + sizeof(TYPE) * (DIMP + nx * (DIMX + DIMOUT) + ny * DIMY)));

    args_d = (TYPE **) p_data;
    TYPE *dataloc = (TYPE *) (args_d + NMINARGS);
    out_d = dataloc;
    dataloc += nx*DIMOUT;

    // host array of pointers to device data
    TYPE *ph[NMINARGS];

      for (int k = 0; k < SIZEP; k++) {
        int indk = INDSP::VAL(k);
        int nvals = DIMSP::VAL(k);        
        CudaSafeCall(cudaMemcpy(dataloc, args_h[indk], sizeof(TYPE) * nvals, cudaMemcpyHostToDevice));
        ph[indk] = dataloc;
        dataloc += nvals;
      }

    for (int k = 0; k < SIZEI; k++) {
      int indk = INDSI::VAL(k);
      int nvals = nx * DIMSX::VAL(k);
      CudaSafeCall(cudaMemcpy(dataloc, args_h[indk], sizeof(TYPE) * nvals, cudaMemcpyHostToDevice));
      ph[indk] = dataloc;
      dataloc += nvals;
    }

      for (int k = 0; k < SIZEJ; k++) {
        int indk = INDSJ::VAL(k);
        int nvals = ny * DIMSY::VAL(k);
        CudaSafeCall(cudaMemcpy(dataloc, args_h[indk], sizeof(TYPE) * nvals, cudaMemcpyHostToDevice));
        ph[indk] = dataloc;
        dataloc += nvals;
      }


    // copy array of pointers
    CudaSafeCall(cudaMemcpy(args_d, ph, NMINARGS * sizeof(TYPE *), cudaMemcpyHostToDevice));

    // Compute on device : grid and block are both 1d
    int dev = -1;
    CudaSafeCall(cudaGetDevice(&dev));

    dim3 blockSize;

    SetGpuProps(dev);

#if ENABLECHUNK // register pressure case...
      blockSize.x = CUDA_BLOCK_SIZE_CHUNKS;
#else
	  // warning : blockSize.x was previously set to CUDA_BLOCK_SIZE; currently CUDA_BLOCK_SIZE value is used as a bound.
      blockSize.x = ::std::min(CUDA_BLOCK_SIZE,
                             ::std::min(maxThreadsPerBlock,
                                        (int) (sharedMemPerBlock / ::std::max(1,
                                                                              (int) (  DIMY
                                                                                  * sizeof(TYPE)))))); // number of threads in each block
#endif
    dim3 gridSize;
    gridSize.x = nx / blockSize.x + (nx % blockSize.x == 0 ? 0 : 1);

#if ENABLECHUNK
      GpuConv1DOnDevice_Chunks<TYPE> 
		  <<< gridSize, blockSize, blockSize.x * DIMCHUNK * sizeof(TYPE) >>> 
			  (fun, nx, ny, out_d, args_d);
#else
      GpuConv1DOnDevice<TYPE> 
		  <<< gridSize, blockSize, blockSize.x * DIMY * sizeof(TYPE) >>> 
			  (fun, nx, ny, out_d, args_d);
#endif

    // block until the device has completed
    CudaSafeCall(cudaDeviceSynchronize());
    CudaCheckError();

    // Send data from device to host.
    CudaSafeCall(cudaMemcpy(out, out_d, sizeof(TYPE) * (nx * DIMOUT), cudaMemcpyDeviceToHost));

    // Free memory.
    CudaSafeCall(cudaFree(p_data));

    return 0;
  }

// and use getlist to enroll them into "pointers arrays" px and py.
  template<typename TYPE, class FUN, typename... Args>
  static int Eval(FUN fun, int nx, int ny, int device_id, TYPE *out, Args... args) {

    if (device_id != -1)
      CudaSafeCall(cudaSetDevice(device_id));

    static const int Nargs = sizeof...(Args);
    TYPE *pargs[Nargs];
    unpack(pargs, args...);

    return Eval_(fun, nx, ny, out, pargs);

  }

// same without the device_id argument
  template<typename TYPE, class FUN, typename... Args>
  static int Eval(FUN fun, int nx, int ny, TYPE *out, Args... args) {
    return Eval(fun, nx, ny, -1, out, args...);
  }

// Idem, but with args given as an array of arrays, instead of an explicit list of arrays
  template<typename TYPE, class FUN>
  static int Eval(FUN fun, int nx, int ny, TYPE *out, TYPE **pargs, int device_id = -1) {

    // We set the GPU device on which computations will be performed
    if (device_id != -1)
      CudaSafeCall(cudaSetDevice(device_id));

    return Eval_(fun, nx, ny, out, pargs);

  }

};

struct GpuConv1D_FromDevice {
  template<typename TYPE, class FUN>
  static int Eval_(FUN fun, int nx, int ny, TYPE *out, TYPE **args) {

    static const int NMINARGS = FUN::NMINARGS;

    // device array of pointers to device data
    TYPE **args_d;

    // single cudaMalloc
    CudaSafeCall(cudaMalloc(&args_d, sizeof(TYPE *) * NMINARGS));

    CudaSafeCall(cudaMemcpy(args_d, args, NMINARGS * sizeof(TYPE *), cudaMemcpyHostToDevice));

    // Compute on device : grid and block are both 1d

    int dev = -1;
    CudaSafeCall(cudaGetDevice(&dev));

    SetGpuProps(dev);

    dim3 blockSize;
#if ENABLECHUNK  // register pressure case...
      blockSize.x = CUDA_BLOCK_SIZE_CHUNKS;
#else
      typedef typename FUN::DIMSY DIMSY;
      const int DIMY = DIMSY::SUM;
	  // warning : blockSize.x was previously set to CUDA_BLOCK_SIZE; currently CUDA_BLOCK_SIZE value is used as a bound.
      blockSize.x = ::std::min(CUDA_BLOCK_SIZE,
                             ::std::min(maxThreadsPerBlock,
                                        (int) (sharedMemPerBlock / ::std::max(1,
                                                                              (int) (  DIMY
                                                                                  * sizeof(TYPE)))))); // number of threads in each block
#endif
	
    dim3 gridSize;
    gridSize.x = nx / blockSize.x + (nx % blockSize.x == 0 ? 0 : 1);

#if ENABLECHUNK
      printf("Hello, using chunks !!\n");
      GpuConv1DOnDevice_Chunks<TYPE> 
		  <<< gridSize, blockSize, blockSize.x * DIMCHUNK * sizeof(TYPE) >>> 
			  (fun, nx, ny, out, args_d);
#else
      GpuConv1DOnDevice<TYPE> <<< gridSize, blockSize, blockSize.x * DIMY * sizeof(TYPE) >>> 
		  (fun, nx, ny, out, args_d);
#endif

    // block until the device has completed
    CudaSafeCall(cudaDeviceSynchronize());

    CudaCheckError();

    CudaSafeCall(cudaFree(args_d));

    return 0;
  }

// Same wrappers, but for data located on the device
  template<typename TYPE, class FUN, typename... Args>
  static int Eval(FUN fun, int nx, int ny, int device_id, TYPE *out, Args... args) {

    // device_id is provided, so we set the GPU device accordingly
    // Warning : is has to be consistent with location of data
    CudaSafeCall(cudaSetDevice(device_id));

    static const int Nargs = sizeof...(Args);
    TYPE *pargs[Nargs];
    unpack(pargs, args...);

    return Eval_(fun, nx, ny, out, pargs);

  }

// same without the device_id argument
  template<typename TYPE, class FUN, typename... Args>
  static int Eval(FUN fun, int nx, int ny, TYPE *out, Args... args) {
    // We set the GPU device on which computations will be performed
    // to be the GPU on which data is located.
    // NB. we only check location of x1_d which is the output vector
    // so we assume that input data is on the same GPU
    // note : cudaPointerGetAttributes has a strange behaviour:
    // it looks like it makes a copy of the vector on the default GPU device (0) !!! 
    // So we prefer to avoid this and provide directly the device_id as input (first function above)
    cudaPointerAttributes attributes;
    CudaSafeCall(cudaPointerGetAttributes(&attributes, out));
    return Eval(fun, nx, ny, attributes.device, out, args...);
  }

  template<typename TYPE, class FUN>
  static int Eval(FUN fun, int nx, int ny, TYPE *out, TYPE **pargs, int device_id = -1) {

    if (device_id == -1) {
      // We set the GPU device on which computations will be performed
      // to be the GPU on which data is located.
      // NB. we only check location of x1_d which is the output vector
      // so we assume that input data is on the same GPU
      // note : cudaPointerGetAttributes has a strange behaviour:
      // it looks like it makes a copy of the vector on the default GPU device (0) !!!
      // So we prefer to avoid this and provide directly the device_id as input (else statement below)
      cudaPointerAttributes attributes;
      CudaSafeCall(cudaPointerGetAttributes(&attributes, out));
      CudaSafeCall(cudaSetDevice(attributes.device));
    } else // device_id is provided, so we use it. Warning : is has to be consistent with location of data
      CudaSafeCall(cudaSetDevice(device_id));

    return Eval_(fun, nx, ny, out, pargs);

  }

};

}
