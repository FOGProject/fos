pipeline {
  agent node
  
  stages {
    stage('Build') {
      steps {
        checkout scm
        sh './build.sh -n'
        
      }
    }
  }
}
