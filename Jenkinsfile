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
    KERNEL_VERSION = '4.18.11'
    BUILDROOT_VERSION = '2018.08.1'
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
/* Disabled for the moment
    stage('Build arm32') {
      steps {
        parallel (
          kernel: {
            sh './build.sh -kn -a arm'
          },
          filesytem: {
            sh './build.sh -fn -a arm'
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
*/
    stage('Upload artifacts') {
      steps {
        archiveArtifacts artifacts: 'dist/*', fingerprint: true
      }
    }
    
  }
}
