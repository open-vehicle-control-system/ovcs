# System.put_env("WIFI_SSID", "OVCS")
# System.put_env("WIFI_PSK", "V8WEjwiU3zHw")
System.put_env("WIFI_SSID", "OVCS-Mini")
System.put_env("WIFI_PSK", "OVCS-Mini")

System.put_env("AUTHORIZED_SSH_KEYS", Enum.join([
  "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICF1a6Pj8MCGEGsoDx6t0IWcKbXrQ3Jr/QSRXRVk80q2 thibault@spin42.com",
  "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOgM6eTRgK/EZmcjy7OHd+/LEuLYE19/MgkiwBcmygek marc.lainez@gmail.com",
  "ecdsa-sha2-nistp521 AAAAE2VjZHNhLXNoYTItbmlzdHA1MjEAAAAIbmlzdHA1MjEAAACFBAA71gnsyJuRsGRI7lNEteJaxSXUvzbh0wZkviQic2/Iv0IoucenB40b9IPfSpDEiz8qXqmlU3hIdS1NnV4LPy3eGgEG/q+eDY55wPQZVa2EwMHgyifBVv5w4owmSiOE//OF23unS2ooKPn4RzoFkDd5gDTC10Y1ZTgpxQtqutxConWSlQ== marc@framework",
  "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCV66oOqkXp3FDYpjWU8FLIon+sCS9qalAzN4zt90gAfjkF05TqYqAnLfRL59xkdgTdIhVr4DfjB5yDgDXG1ZTdFCsNZQPiJR6SFWEGUbc8gTCN+OoQcvpHndU/SeeU1SM/XsnLkQSf68q43PjPHZdujkJaerjwW7T9eJEGULTNNWizNnC72NEq7LVaQ7NFXs+i5v1mcCK4xr6m62WiHbYhBzXcfWFlZTFUeeLIkR1R4OBCh2WwVLrO2Y3fVSkIUYPMusMtkzgfp55WuhNSVQuWFp7TTt6UPpJCtLvKay8xzmaKR/BnSkltElDBkQByFlUrf4QSwlKUR0B+31v6nPyoK/fyC2v/720uqPdvPWYjl9wjlJnyIKIDBNPSb9ehYWfLmZTMA5x5dzdGYvm1sabBlCIWXZi1Gje5uNg+hz37AAdp0vFPwtG0yq3rhoK2bqdW/Qk7bNaxnIi30Raw9SHR2+nOqZkVmb8NC+JJJ3Vhzy61aUilPMopMur8akVmaQU= loo@loo-fmwk",
], ","))
System.put_env("SECRET_KEY_BASE", "488503fb7d9dde7044d69d7ee07c278127cb25014b0a8425fb8004ed4f122b44")
System.put_env("SIGNING_SALT", "06ca2849746cdd32654ea784")
