# ~/Bastion/BASTION3/boundary-controller/controller.hcl
disable_mlock = true

controller {
  name        = "controller-3"
  description = "Boundary controller"
  database {
    url = "env://BOUNDARY_POSTGRES_URL"
  }
}

listener "tcp" {
  address     = "0.0.0.0:9200"
  purpose     = "api"
  tls_disable = true
}

listener "tcp" {
  address     = "0.0.0.0:9201"
  purpose     = "cluster"
  tls_disable = true
}

kms "aead" {
  purpose   = "root"
  aead_type = "aes-gcm"
  key       = "0bsfXQc6PhmIMtBz32pkn71jdmePacZMpXzk/q2pkfA="
  key_id    = "global_root"
}

kms "aead" {
  purpose   = "worker-auth"
  aead_type = "aes-gcm"
  key       = "Ii0voCl+0jEoODgbQM/LmQI+9jefhUxDyUdd9lk2qso="
  key_id    = "global_worker-auth"
}

kms "aead" {
  purpose   = "recovery"
  aead_type = "aes-gcm"
  key       = "4unlJNN9ouvKjPjStx2AnQ1eXomd23eOXkxsi9vvLxU="
  key_id    = "global_recovery"
}
