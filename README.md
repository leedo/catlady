Create a new database using `usealice.sql`. The only table
that really matters is `users`, users should go in there.

<pre>
  git clone https://github.com/leedo/alice.git
  git clone https://github.com/leedo/catlady.git
  cd catlady
  ln -s ../alice/share .
  mkdir -p etc/users
  vim config.json
  perl -Ilib -I../alice/lib bin/catlady config.json
</pre>
