pipeline {
  agent { 
    node { 
      label 'fos'
    }
  }
  environment {
    KERNEL_VERSION = '4.18.11'
    BUILDROOT_VERSION = '2018.02.2'
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
