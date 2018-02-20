pipeline {
  agent { node { label 'fos' } }
  
  stages {
    stage('Build') {
      steps {
        checkout scm
        
        parallel (
          "Kernel - x86": {
            sh './build.sh -kn -a x86'
          },
          "Kernel - x64": {
            sh './build.sh -kn -a x64'
          },
          "Filesystem - x86": {
            sh './build.sh -fn -a x86'
          },
          "Filesystem - x64": {
            sh './build.sh -fn -a x64'
          },
          
        )
      }
    }
  }
}
