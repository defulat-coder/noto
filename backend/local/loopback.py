"""Rebind only this project's CLI-created containers to loopback, keeping volumes.
Supabase CLI explicitly binds all interfaces, overriding Docker network defaults.
"""
import http.client, json, socket, subprocess, os

class DockerHTTP(http.client.HTTPConnection):
    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.connect((os.environ.get('DOCKER_HOST') or subprocess.check_output(['docker','context','inspect','--format','{{.Endpoints.docker.Host}}'], text=True).strip()).removeprefix('unix://'))

def request(method, path, value=None):
    connection = DockerHTTP('localhost')
    connection.request(method, '/v1.51' + path, None if value is None else json.dumps(value), {'Content-Type':'application/json'})
    response = connection.getresponse()
    data = response.read()
    if response.status >= 300: raise RuntimeError(data.decode())
    return json.loads(data) if data else None

for name in ['supabase_db_noto','supabase_kong_noto','supabase_inbucket_noto']:
    try: info = request('GET', '/containers/' + name + '/json')
    except RuntimeError: continue
    bindings = info['HostConfig'].get('PortBindings') or {}
    if not any(binding['HostIp'] != '127.0.0.1' for values in bindings.values() for binding in values or []): continue
    for values in bindings.values():
        for binding in values or []: binding['HostIp'] = '127.0.0.1'
    # CLI copies generated gateway files into the writable layer; retain them.
    snapshot = request('POST', '/commit?container=' + name + '&pause=true')
    config = dict(info['Config'], HostConfig=info['HostConfig'])
    config['Image'] = snapshot['Id']
    config['NetworkingConfig'] = {'EndpointsConfig': {network: {'Aliases':[name]} for network in info['NetworkSettings']['Networks']}}
    request('POST', '/containers/' + name + '/stop')
    request('POST', '/containers/' + name + '/rename?name=' + name + '-prior-binding')
    request('POST', '/containers/create?name=' + name, config)
    request('POST', '/containers/' + name + '/start')
    request('DELETE', '/containers/' + name + '-prior-binding')
    print('Bound to loopback:', name)
