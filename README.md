Create a new database using `usealice.sql`. The only table
that really matters is `users`, users should go in there.

<pre>
  git clone git@github.com:leedo/alice.git
  git clone git@github.com:leedo/catlady.git
  cd catlady
  ln -s ../alice/share .
  mkdir -p etc/users var
  perl -Ilib -I../alice/lib bin/catlady
</pre>
