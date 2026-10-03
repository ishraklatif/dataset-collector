import os
bind='0.0.0.0:'+os.getenv('PORT','8000')
workers=2
threads=2
timeout=180
limit_request_field_size=32768
limit_request_fields=30
accesslog=None  # URL paths may contain scoped download capabilities; never log them.
errorlog='-'
capture_output=False
