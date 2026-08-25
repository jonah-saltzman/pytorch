# Magma build scripts need `python`
ln -sf /usr/bin/python3 /usr/bin/python

if [[ -f /etc/rocm_env.sh ]]; then
    source /etc/rocm_env.sh
elif command -v rocm-sdk >/dev/null 2>&1; then
    ROCM_HOME="$(rocm-sdk path --root)"
elif command -v hipcc >/dev/null 2>&1; then
    ROCM_HOME="$(cd "$(dirname "$(command -v hipcc)")/.." && pwd)"
fi
: "${ROCM_HOME:?Unable to discover ROCm installation root}"

ID=$(grep -oP '(?<=^ID=).+' /etc/os-release | tr -d '"')
case "$ID" in
  almalinux)
    yum install -y gcc-gfortran
    ;;
  *)
    echo "No preinstalls to build magma..."
    ;;
esac

MKLROOT=${MKLROOT:-/opt/conda/envs/py_$ANACONDA_PYTHON_VERSION}

cp make.inc-examples/make.inc.hip-gcc-mkl make.inc
echo 'LIBDIR += -L$(MKLROOT)/lib' >> make.inc
if [[ -f "${MKLROOT}/lib/libmkl_core.a" ]]; then
    echo 'LIB = -Wl,--start-group -lmkl_gf_lp64 -lmkl_gnu_thread -lmkl_core -Wl,--end-group -lpthread -lstdc++ -lm -lgomp -lhipblas -lhipsparse' >> make.inc
fi
echo "LIB += -Wl,--enable-new-dtags -Wl,--rpath,${ROCM_HOME}/lib -Wl,--rpath,\$(MKLROOT)/lib -Wl,--rpath,${ROCM_HOME}/magma/lib -ldl" >> make.inc
echo 'DEVCCFLAGS += --gpu-max-threads-per-block=256' >> make.inc
export PATH="${ROCM_HOME}/bin:${PATH}"
if [[ -n "$PYTORCH_ROCM_ARCH" ]]; then
  amdgpu_targets=`echo $PYTORCH_ROCM_ARCH | sed 's/;/ /g'`
else
  amdgpu_targets=`rocm_agent_enumerator | grep -v gfx000 | sort -u | xargs`
fi
for arch in $amdgpu_targets; do
  echo "DEVCCFLAGS += --offload-arch=$arch" >> make.inc
done
# hipcc with openmp flag may cause isnan() on __device__ not to be found; depending on context, compiler may attempt to match with host definition
sed -i 's/^FOPENMP/#FOPENMP/g' make.inc
make -f make.gen.hipMAGMA -j $(nproc)
LANG=C.UTF-8 make lib/libmagma.so -j $(nproc) MKLROOT="${MKLROOT}"
make testing/testing_dgemm -j $(nproc) MKLROOT="${MKLROOT}"
cp -R lib ${INSTALL_DIR}
cp -R include ${INSTALL_DIR}
