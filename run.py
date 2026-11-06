"""Start the app:  python run.py   then open http://localhost:5000"""
import os

from cm.app import create_app

app = create_app()

if __name__ == "__main__":
    app.run(host=os.environ.get("CM_HOST", "127.0.0.1"), port=int(os.environ.get("CM_PORT", 5000)),
            debug=bool(os.environ.get("CM_DEBUG")))
