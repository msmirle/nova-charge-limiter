# Puts nova-charge-limit on PATH; /usr/local is read-only on Armada OS.
case ":${PATH}:" in
    *:/var/lib/nova-charge-limit/bin:*) ;;
    *) PATH="${PATH}:/var/lib/nova-charge-limit/bin" ;;
esac
