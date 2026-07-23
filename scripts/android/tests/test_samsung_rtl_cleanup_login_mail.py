import importlib.util
import pathlib
import sys
import unittest


SCRIPT = pathlib.Path(__file__).resolve().parents[1] / "samsung-rtl-cleanup-login-mail.py"


def load_module():
    spec = importlib.util.spec_from_file_location("samsung_rtl_cleanup_login_mail", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


class SamsungRtlCleanupLoginMailTests(unittest.TestCase):
    def setUp(self):
        self.module = load_module()

    def test_selects_only_exact_samsung_login_notices_in_window(self):
        messages = [
            self.module.MailCandidate(
                uid=b"101",
                date_header="Sun, 28 Jun 2026 13:03:34 +0000",
                sender="Samsung account <sa.noreply@samsung-mail.com>",
                subject="New sign-in to your Samsung account",
                message_id="<first@example.test>",
            ),
            self.module.MailCandidate(
                uid=b"102",
                date_header="Sun, 28 Jun 2026 13:03:34 +0000",
                sender="Samsung account <marketing@samsung-mail.com>",
                subject="New sign-in to your Samsung account",
                message_id="<wrong-sender@example.test>",
            ),
            self.module.MailCandidate(
                uid=b"103",
                date_header="Sun, 28 Jun 2026 13:03:34 +0000",
                sender="Samsung account <sa.noreply@samsung-mail.com>",
                subject="Samsung account update",
                message_id="<wrong-subject@example.test>",
            ),
            self.module.MailCandidate(
                uid=b"104",
                date_header="Sun, 28 Jun 2026 12:00:00 +0000",
                sender="Samsung account <sa.noreply@samsung-mail.com>",
                subject="New sign-in to your Samsung account",
                message_id="<too-old@example.test>",
            ),
        ]

        selected = self.module.select_login_notices(
            messages,
            since_epoch=1782651600,
            now_epoch=1782652620,
            lookback_seconds=300,
        )

        self.assertEqual([m.uid for m in selected], [b"101"])

    def test_formats_uid_set_for_imap_move(self):
        selected = [
            self.module.MailCandidate(
                uid=b"101",
                date_header="Sun, 28 Jun 2026 13:03:34 +0000",
                sender="Samsung account <sa.noreply@samsung-mail.com>",
                subject="New sign-in to your Samsung account",
                message_id="<first@example.test>",
            ),
            self.module.MailCandidate(
                uid=b"105",
                date_header="Sun, 28 Jun 2026 13:04:01 +0000",
                sender="Samsung account <sa.noreply@samsung-mail.com>",
                subject="New sign-in to your Samsung account",
                message_id="<second@example.test>",
            ),
        ]

        self.assertEqual(self.module.uid_set(selected), b"101,105")


if __name__ == "__main__":
    unittest.main()
