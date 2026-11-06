from fastapi.testclient import TestClient

from hermes_bridge.app import create_app
from hermes_bridge.config import BridgeConfig


def test_paired_devices_share_icons_and_revoked_or_replayed_tickets_fail(tmp_path):
    config = BridgeConfig(db_path=tmp_path / 'bridge.db')
    app = create_app(config)
    runtime = app.state.bridge
    for device in ('phone', 'mac'):
        runtime.registry.add_device(device_id=device, name=device, platform='test',
                                    public_key='test', refresh_token='secret-' + device)
    with TestClient(app) as client:
        def ticket(device):
            response = client.post('/v1/token', json={'device_id': device, 'refresh_token': 'secret-' + device})
            return response.json()['ws_ticket']
        def headers(device):
            return {'Authorization': 'Bearer ' + ticket(device)}
        assert client.get('/v1/bot-icons').status_code == 401
        reused = headers('phone')
        assert client.put('/v1/bot-icons/research', headers=reused, json={'icon': 'ember'}).status_code == 200
        assert client.get('/v1/bot-icons', headers=reused).status_code == 401
        assert client.get('/v1/bot-icons', headers=headers('mac')).json() == {'icons': {'research': 'ember'}}
        assert client.put('/v1/bot-icons/research', headers=headers('mac'), json={'icon': 'unknown'}).status_code == 422
        revoked = headers('phone')
        runtime.registry.revoke('phone')
        assert client.get('/v1/bot-icons', headers=revoked).status_code == 401
    restarted = create_app(config)
    with TestClient(restarted) as client:
        t = client.post('/v1/token', json={'device_id': 'mac', 'refresh_token': 'secret-mac'}).json()['ws_ticket']
        assert client.get('/v1/bot-icons', headers={'Authorization': 'Bearer ' + t}).json() == {'icons': {'research': 'ember'}}
