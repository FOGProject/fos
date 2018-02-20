#!groovy

stage('Build') {
  parallel x86Kernel: {
    node {
      checkout scm
      sh './build.sh -kn -a x86'
    }
  },
  x86Kernel: {
    node {
      checkout scm
      sh './build.sh -kn -a x64'
    }
  },
  x86Filesystem: {
    node {
      checkout scm
      sh './build.sh -fn -a x86'
    }
  },
  x86Filesystem: {
    node {
      checkout scm
      sh './build.sh -fn -a x64'
    }
  }
}
