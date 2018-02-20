pipeline {
  agent { node { label 'fos' } }
  
  stages {
    stage('SCM') {
      steps {
        checkout scm
      }
    },
    stage('Build x86') {
      parallel {
        stage('Kernel') {
          steps {
            sh './build.sh -kn -a x86'
          }
        },
        stage('Filesystem') {
          steps {
            sh './build.sh -fn -a x86'
          }
        }
      }
    },
    stage('Build x64') {
      parallel {
        stage('Kernel') {
          steps {
            sh './build.sh -kn -a x64'
          }
        },
        stage('Filesystem') {
          steps {
            sh './build.sh -fn -a x64'
          }
        }
      }
    }
  }
}
