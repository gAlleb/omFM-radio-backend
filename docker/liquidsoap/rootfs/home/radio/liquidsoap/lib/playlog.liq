# Защита от повторов: журнал сыгранного и проверка кандидата на эфир.
# Логика не менялась при выносе в библиотеку, параметрами стали только
# окно неповтора и необязательный колбэк на принятый трек.

stopwords = [
  "a",
  "with",
  ",",
  "&",
  "the",
  "feat",
  "vs",
  "manose",
  "miten",
  "and"
]

def tokenize(a)
  b = string.case(a, lower=true)
  c = r/[^\w'-]+/.split(b)
  # TODO: normalize
  d = list.filter(fun(i) -> not list.mem(i, stopwords), c)
  list.sort.natural(d)
end

def my_hash(m)
  artist = metadata.artist(m)
  string.concat(tokenize(artist), separator=" ")
end

l = playlog(
  persistency="#{log_dir}/songs_check_#{station}.log",
  duration=7200.,
  hash=my_hash
)

# window     — сколько секунд артист не должен повторяться
# on_accept  — вызывается на принятом треке; станция может запомнить
#              его метаданные, чтобы отдать наружу как "следующий трек"
def make_check(~on_accept=fun(_) -> (), window)
  fun (r) ->
    if request.resolve(r) then
      m = request.metadata(r)

      if l.last(m) < window then
        log(level=3, "Rejecting #{m['artist']} (played #{l.last(m)}s ago).")
        false
      else
        l.add(m)
        on_accept(m)
        true
      end
    else
      false
    end
end
