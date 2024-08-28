ARG DRIVER_TOOLKIT_IMAGE="quay.io/smgglrs-ai/driver-toolkit:latest"
ARG BASE_IMAGE="quay.io/fedora/fedora-bootc:40"

FROM ${DRIVER_TOOLKIT_IMAGE} AS builder

ARG DRIVER_VERSION=
# There is no repository for CentOS Stream, so using RHEL one
ARG HABANA_REPO_URL="https://vault.habana.ai/artifactory/rhel/9/9.4"

WORKDIR /home/builder

RUN export DISTRO=$(grep '^ID=' /etc/os-release | cut -d '=' -f 2 | sed 's/"//g') \
    && export OS_VERSION_MAJOR=$(grep '^VERSION_ID=' /etc/os-release | cut -d '=' -f 2 | cut -d'.' -f 1 | sed 's/"//g') \
    && export KERNEL_VERSION=$(rpm -q --qf '%{VERSION}-%{RELEASE}' kernel-core) \
    && export BUILD_ARCH=$(arch) \
    && export TARGET_ARCH=$(echo "${BUILD_ARCH}" | sed 's/+64k//') \
    && rpm2cpio ${HABANA_REPO_URL}/habanalabs-firmware-${DRIVER_VERSION}.el${OS_VERSION_MAJOR}.${TARGET_ARCH}.rpm | cpio -idm \
    && rpm2cpio ${HABANA_REPO_URL}/habanalabs-${DRIVER_VERSION}.el${OS_VERSION_MAJOR}.noarch.rpm | cpio -idm \
    && rpm2cpio ${HABANA_REPO_URL}/habanalabs-rdma-core-${DRIVER_VERSION}.el${OS_VERSION_MAJOR}.noarch.rpm | cpio -idm \
    && rpm2cpio ${HABANA_REPO_URL}/habanalabs-firmware-tools-${DRIVER_VERSION}.el${OS_VERSION_MAJOR}.${TARGET_ARCH}.rpm | cpio -idm \
    && rpm2cpio ${HABANA_REPO_URL}/habanalabs-thunk-${DRIVER_VERSION}.el${OS_VERSION_MAJOR}.${TARGET_ARCH}.rpm | cpio -idm \
    && pushd usr/src/habanalabs-${DRIVER_VERSION} \
    && make -f Makefile.nic KVERSION=${KERNEL_VERSION}.${TARGET_ARCH} \
    && make -f Makefile KVERSION=${KERNEL_VERSION}.${TARGET_ARCH} \
    && pushd drivers/infiniband/hw/hbl \
    && make KVERSION=${KERNEL_VERSION}.${TARGET_ARCH}

FROM ${BASE_IMAGE}

ARG DRIVER_VERSION=

COPY build/usr /usr

RUN --mount=type=bind,from=builder,source=/,destination=/tmp/builder,ro \
    export DISTRO=$(grep '^ID=' /etc/os-release | cut -d '=' -f 2 | sed 's/"//g') \
    && export KERNEL_VERSION=$(rpm -q --qf '%{VERSION}-%{RELEASE}' kernel-core) \
    && export BUILD_ARCH=$(arch) \
    && export TARGET_ARCH=$(echo "${BUILD_ARCH}" | sed 's/+64k//') \
    && mkdir -p /lib/modules/${KERNEL_VERSION}.${TARGET_ARCH}/extra \
    && cp /tmp/builder/home/builder/usr/src/habanalabs-${DRIVER_VERSION}/drivers/accel/habanalabs/habanalabs.ko \
        /tmp/builder/home/builder/usr/src/habanalabs-${DRIVER_VERSION}/drivers/infiniband/hw/hbl/habanalabs_ib.ko \
        /tmp/builder/home/builder/usr/src/habanalabs-${DRIVER_VERSION}/drivers/net/ethernet/intel/hbl_cn/habanalabs_cn.ko \
        /tmp/builder/home/builder/usr/src/habanalabs-${DRIVER_VERSION}/drivers/net/ethernet/intel/hbl_en/habanalabs_en.ko \
        /lib/modules/${KERNEL_VERSION}.${TARGET_ARCH}/extra/ \
    && if [ "${DISTRO}" == "centos" ] ; then \
        dnf config-manager --set-enabled crb ; \
    elif [ "${DISTRO}" == "rhel" ] ; then \
        dnf config-manager --set-enabled codeready-builder-for-rhel-9-$(arch)-rpms ; \
    fi \
    && cp /tmp/repos.d/${DISTRO}/${TARGET_ARCH}/intel-gaudi.repo /etc/yum.repos.d/intel-gaudi.repo \
    && cp /tmp/repos.d/${DISTRO}/${TARGET_ARCH}/RPM-GPG-KEY-INTEL-GAUDI /etc/pki/rpm-gpg/RPM-GPG-KEY-INTEL-GAUDI \
    && rpm --import /etc/pki/rpm-gpg/RPM-GPG-KEY-INTEL-GAUDI \
    && cp /tmp/repos.d/${DISTRO}/${TARGET_ARCH}/epel.repo /etc/yum.repos.d/epel.repo \
    && cp /tmp/repos.d/${DISTRO}/${TARGET_ARCH}/RPM-GPG-KEY-EPEL-9 /etc/pki/rpm-gpg/RPM-GPG-KEY-EPEL-9 \
    && rpm --import /etc/pki/rpm-gpg/RPM-GPG-KEY-EPEL-9 \
    && cp -a /etc/dnf/dnf.conf{,.tmp} && mv /etc/dnf/dnf.conf{.tmp,} \
    && dnf config-manager --best --nodocs --setopt=install_weak_deps=False --save \
    && mv /etc/selinux /etc/selinux.tmp \ 
    && dnf update -y --exclude=kernel* \
    && dnf install -y \
        habanalabs-container-runtime \
        habanalabs-firmware \
        habanalabs-firmware-tools \
        habanalabs-rdma-core \
        habanalabs-thunk \
        habanatools \
        pciutils \
        rsync \
        skopeo \
    && dnf clean all \
    && mv /etc/selinux.tmp /etc/selinux
#    && cp -r /tmp/builder/home/builder/lib/firmware/habanalabs /lib/firmware/ \

ARG SSHPUBKEY

# The --build-arg "SSHPUBKEY=$(cat ~/.ssh/id_rsa.pub)" option inserts your
# public key into the image, allowing root access via ssh.
RUN if [ -n "${SSHPUBKEY}" ]; then \
    set -eu; mkdir -p /usr/ssh && \
        echo 'AuthorizedKeysFile /usr/ssh/%u.keys .ssh/authorized_keys .ssh/authorized_keys2' >> /etc/ssh/sshd_config.d/30-auth-system.conf && \
            echo ${SSHPUBKEY} > /usr/ssh/root.keys && chmod 0600 /usr/ssh/root.keys; \
fi

# Setup /usr/lib/containers/storage as an additional store for images.
# Remove once the base images have this set by default.
RUN grep -q /usr/lib/containers/storage /etc/containers/storage.conf || \
    sed -i -e '/additionalimage.*/a "/usr/lib/containers/storage",' \
        /etc/containers/storage.conf

# Added for running as an OCI Container to prevent Overlay on Overlay issues.
VOLUME /var/lib/containers

LABEL description="Bootc for AMD ROCm provides a container runtime for AMD ROCm accelerated workloads" \
      name="bootc-amd-rocm" \
      org.opencontainers.image.name="bootc-amd-rocm" \
      vcs-ref="${VCS_REF}"
