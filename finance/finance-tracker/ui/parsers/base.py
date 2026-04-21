class BankMismatchError(Exception):
    """Raised when a PDF's content does not match the bank its parser expects."""
