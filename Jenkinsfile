pipeline {
  agent { 
    node { 
      label 'fos'
    }
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
            sh '/home/builder/fos/build.sh -kn -a x86'
          },
          filesytem: {
            sh '/home/builder/fos/build.sh -fn -a x86'
          }
        )
      }
    }
    stage('Build x64') {
      steps {
        parallel (
          kernel: {
            sh '/home/builder/fos/build.sh -kn -a x64'
          },
          filesytem: {
            sh '/home/builder/fos/build.sh -fn -a x64'
          }
        )
      }
    }
  }
}
