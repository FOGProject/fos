pipeline {
  agent { node { label 'fos' } }
  
  stages {
    stage('Build') {
      steps {
        checkout scm
        sh './build.sh -n'
        
      }
    }
  }
}
