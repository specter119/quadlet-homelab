#!/bin/bash
# Post-deploy hook: reload systemd user services after dotter deploy
systemctl --user daemon-reload
