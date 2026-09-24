Deploying operator via ansible and managing OCP via ansible
===========================================================

Ref: https://docs.google.com/document/d/1Slk4w5j32_4OVhaKqkFRsj3iyAgve6AMtFdLMkN56_w/edit?tab=t.0

--------------
On the bastion
--------------
##  Install ansible
Step 1: Install System & Python Packages via dnf
~~~
sudo dnf install -y ansible-core

~~~

## Install ansible collections - for disconnected environment
Step 1: downlaod the ansible collections
~~~
mkdir offline-bundle
ansible-galaxy collection download kubernetes.core -p offline-bundle/collections
~~~

Step 2: After transfering the offline-bundle to the disconnected server.
        Install the kubenetes collection
~~~
mkdir collections
ansible-galaxy collection install ../offline-bundle/collections/kubernetes-core-6.6.0.tar.gz -p collections --offline
~~~

Step 3: create the ansible.cfg configuration file and update it with the new collections folder
~~~
vim ansible.cfg
  ~~~
  COLLECTIONS_PATHS = ./collections
  ~~~
~~~

Step 3: Verify the install ansible collections
~~~
ansible-galaxy collection list
  ~~~
  Collection      Version
  --------------- -------
  kubernetes.core 6.6.0  
  ~~~

~~~

