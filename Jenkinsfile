pipeline {
  agent any
  stages {
    stage('Build') {
      parallel x86Kernel: {
        node('fos') {
          checkout scm
          sh './build.sh -kn -a x86'
        }
      },
      x64Kernel: {
        node('fos') {
          checkout scm
          sh './build.sh -kn -a x64'
        }
     },
      x86Filesystem: {
       node('fos') {
          checkout scm
          sh './build.sh -fn -a x86'
       }
     },
      x64Filesystem: {
       node('fos') {
         checkout scm
         sh './build.sh -fn -a x64'
       }
     }
    }
  }
}
