pipeline {
  agent { 
    node { 
      label 'fos'
      customWorkspace 'workspace/fos_master-build'
    }
  }
  options {
    skipDefaultCheckout()
  }
  environment {
    KERNEL_VERSION = '4.19.123'
    BUILDROOT_VERSION = '2020.02.2'
  }
  stages {
    stage('SCM') {
      steps {
        checkout scm
      }
    }
    stage('Build x86') {
      steps {
        parallel (
          kernel: {
            sh './build.sh -kn -a x86'
          },
          filesytem: {
            sh './build.sh -fn -a x86'
          }
        )
      }
    }
    stage('Build x64') {
      steps {
        parallel (
          kernel: {
            sh './build.sh -kn -a x64'
          },
          filesytem: {
            sh './build.sh -fn -a x64'
          }
        )
      }
    }
    stage('Build arm64') {
      steps {
        parallel (
          kernel: {
            sh './build.sh -kn -a arm64'
          },
          filesytem: {
            sh './build.sh -fn -a arm64'
          }
        )
      }
    }
    stage('Upload artifacts') {
      steps {
        archiveArtifacts artifacts: 'dist/*', fingerprint: true
      }
    }
    
  }
}
