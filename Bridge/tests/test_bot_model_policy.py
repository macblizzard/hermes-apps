from hermes_bridge.policy import is_bot_model_configure_allowed


def test_only_explicit_profile_model_changes_are_allowed():
    good = {"name": "bot-a", "model": "model-x", "provider": "provider-y"}
    assert is_bot_model_configure_allowed(good)
    assert is_bot_model_configure_allowed({**good, "confirm_expensive_model": True})
    for bad in ({**good, "soul": "overwrite"}, {**good, "name": ""},
                {**good, "provider": " "}, {**good, "confirm_expensive_model": "true"},
                {**good, "model": ["x"]}, None):
        assert not is_bot_model_configure_allowed(bad)
