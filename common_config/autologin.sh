setup_autologin()
{
  {
    echo "# ${live_user} autologin"
    echo "${live_user}:\\" 
    echo ":al=${live_user}:ht:np:sp#115200:"
  } >> "${release}/etc/gettytab"

  sed -i "" "/ttyv0/s/Pc/${live_user}/g" "${release}/etc/ttys"

  cat > "${release}/home/${live_user}/.zprofile" <<'EOF'
if [ "$(tty)" = "/dev/ttyv0" ] && [ -z "$DISPLAY" ]; then
  startx
fi
EOF

  chmod 755 "${release}/home/${live_user}/.zprofile"
}
