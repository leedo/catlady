Create a new database using `usealice.sql`. The only table
that really matters is `users`, users should go in there.

<pre>
  git clone https://github.com/leedo/alice.git
  cpanm -S -n --installdeps ./alice
  git clone https://github.com/leedo/catlady.git
  cd catlady
  cpanm -S -n Digest::SHA1 Plack::Middleware::ReverseProxy Plack::Session AnyEvent::DBI::Abstract Path::Class Digest::HMAC
  ln -s ../alice/share .
  mkdir -p etc/users
  cp config.example.js config.json
  vim config.json
  perl -Ilib -I../alice/lib bin/catlady config.json
</pre>
