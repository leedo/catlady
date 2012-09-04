Create a new database using `usealice.sql`. The only table
that really matters is `users`, users should go in there.

<pre>
  git clone https://github.com/leedo/catlady.git
  cd catlady
  git submodule init
  git submodule update
  cpanm -S -n --installdeps .
  cpanm -S -n --installdeps ./alice
  mkdir users
  cp config.example.js config.json
  vim config.json
  perl -Ilib -Ialice/lib bin/catlady config.json
</pre>
