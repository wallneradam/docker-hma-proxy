import logging as log


def setup():
    import conf
    log.basicConfig(level=conf.LOG_LEVEL.upper(),
                    format="%(asctime)s [ %(levelname)5s ] %(message)s")

setup()
