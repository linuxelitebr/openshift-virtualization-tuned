#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <stdint.h>
static uint64_t rng=88172645463325252ULL;
static inline uint64_t xs(){ rng^=rng<<13; rng^=rng>>7; rng^=rng<<17; return rng; }
int main(void){
  size_t N = 512UL*1024*1024;          /* 512M * 8B = 4 GiB working set */
  size_t iters = 250UL*1000*1000;      /* 250M dependent chases */
  size_t *a = malloc(N*sizeof(size_t));
  if(!a){ printf("alloc fail\n"); return 1; }
  for(size_t i=0;i<N;i++) a[i]=i;
  for(size_t i=N-1;i>0;i--){ size_t j=xs()%i; size_t t=a[i]; a[i]=a[j]; a[j]=t; } /* Sattolo single cycle */
  size_t idx=0;
  struct timespec t0,t1; clock_gettime(CLOCK_MONOTONIC,&t0);
  for(size_t i=0;i<iters;i++) idx=a[idx];
  clock_gettime(CLOCK_MONOTONIC,&t1);
  volatile size_t sink=idx; (void)sink;
  double sec=(t1.tv_sec-t0.tv_sec)+(t1.tv_nsec-t0.tv_nsec)/1e9;
  printf("pointer-chase: %.1f GiB set, %zu accesses, %.3fs => %.2f ns/access, %.1f M-acc/s\n",
         N*8.0/1073741824.0, iters, sec, sec/iters*1e9, iters/sec/1e6);
  return 0;
}
