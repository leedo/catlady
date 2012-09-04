Create a new database using the provided SQL.

Setup catlady:

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
</pre>

Run the catlady:

<pre>
  perl -Ilib -Ialice/lib bin/catlady config.json
</pre>
