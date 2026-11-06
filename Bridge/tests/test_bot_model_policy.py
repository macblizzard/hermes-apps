from hermes_bridge.policy import is_bot_model_configure_allowed

GOOD_MODEL = {"name": "bot-a", "model": "model-x", "provider": "provider-y"}


def test_only_explicit_profile_model_changes_are_allowed():
    assert is_bot_model_configure_allowed(GOOD_MODEL)
    assert is_bot_model_configure_allowed({**GOOD_MODEL, "confirm_expensive_model": True})
    for bad in ({**GOOD_MODEL, "soul": "overwrite"}, {**GOOD_MODEL, "name": ""},
                {**GOOD_MODEL, "provider": " "}, {**GOOD_MODEL, "confirm_expensive_model": "true"},
                {**GOOD_MODEL, "model": ["x"]}, None):
        assert not is_bot_model_configure_allowed(bad)


def test_description_alone_is_allowed():
    assert is_bot_model_configure_allowed({"name": "cody", "description": "Lead Developer of Moe's Homelab"})


def test_empty_description_is_allowed_so_it_can_be_cleared():
    assert is_bot_model_configure_allowed({"name": "cody", "description": ""})


def test_description_may_travel_with_a_model_change():
    assert is_bot_model_configure_allowed({
        **GOOD_MODEL, "description": "Lead Developer", "confirm_expensive_model": False,
    })


def test_description_must_be_a_string():
    for bad in ({"name": "cody", "description": None},
                {"name": "cody", "description": ["Lead Developer"]},
                {"name": "cody", "description": {"text": "Lead Developer"}},
                {"name": "cody", "description": 7}):
        assert not is_bot_model_configure_allowed(bad)


def test_description_does_not_open_the_other_sections():
    for bad in ({"name": "cody", "description": "Lead Developer", "soul": "overwrite"},
                {"name": "cody", "description": "Lead Developer", "ui_meta": {}},
                {"name": "cody", "description": "Lead Developer", "enabled_toolsets": []},
                {"name": "cody", "description": "Lead Developer", "disabled_skills": []}):
        assert not is_bot_model_configure_allowed(bad)


def test_description_still_requires_a_name():
    assert not is_bot_model_configure_allowed({"description": "Lead Developer"})
    assert not is_bot_model_configure_allowed({"name": "  ", "description": "Lead Developer"})
    assert not is_bot_model_configure_allowed({"name": "cody"})


def test_model_pair_must_be_complete_even_beside_a_description():
    assert not is_bot_model_configure_allowed(
        {"name": "cody", "model": "model-x", "description": "Lead Developer"})
    assert not is_bot_model_configure_allowed(
        {"name": "cody", "provider": "provider-y", "description": "Lead Developer"})


def test_confirmation_is_refused_without_a_model_change():
    assert not is_bot_model_configure_allowed(
        {"name": "cody", "description": "Lead Developer", "confirm_expensive_model": True})
