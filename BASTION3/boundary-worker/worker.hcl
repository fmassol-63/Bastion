# ~/Bastion/BASTION3/boundary-worker/worker.hcl
disable_mlock = true

listener "tcp" {
  address     = "0.0.0.0:9202"
  purpose     = "proxy"
  tls_disable = true
}

worker {
  name        = "worker-1"
  description = "Boundary worker"
  public_addr = "192.168.200.105"

  initial_upstreams = [
    "192.168.200.101:9201",
    "192.168.200.103:9201"
  ]
}

kms "aead" {
  purpose   = "worker-auth"
  aead_type = "aes-gcm"
  key       = "Ii0voCl+0jEoODgbQM/LmQI+9jefhUxDyUdd9lk2qso="
  key_id    = "global_worker-auth"
}
