from app.broker.mt5_errors import explain


def test_known_codes_get_plain_advice() -> None:
    assert "password" in explain(-6, "Authorization failed")
    assert "did not answer" in explain(-10005, "IPC timeout")
    assert "did not answer" in explain(-10001, "IPC send failed")


def test_process_create_failed_points_to_the_copy_and_update() -> None:
    text = explain(-10003, "IPC initialize failed, Process create failed 'C:\\x\\terminal64.exe'")
    assert "copy" in text and "Update" in text


def test_unknown_code_keeps_mt5_words() -> None:
    text = explain(-99, "Something odd")
    assert "Something odd" in text and "-99" in text


def test_auth_message_without_known_code() -> None:
    assert "password" in explain(-1, "Authorization failed (custom)")
