# Optional nginx snippets

Any `*.conf` placed here is copied by `deploy.sh render` to
`$DATA_DIR/nginx/includes/` and included inside `location /` of the main
server (e.g. `set_real_ip_from` lists: `cf_ips.conf`, `mostbet_ips.conf`).

Cloudflare example (`cf_ips.conf`):

    # https://www.cloudflare.com/ips-v4/
    set_real_ip_from 173.245.48.0/20;
    set_real_ip_from 103.21.244.0/22;
    # ...
