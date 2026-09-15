from typing import Optional

from fastapi.responses import HTMLResponse
from pydantic import BaseModel

from fastapi import FastAPI

# GET /user/123
# WSGI / ASGI

class CreateUserRequest(BaseModel):
    name: str
    age: int
    email: str



app = FastAPI()

@app.get("/", response_class=HTMLResponse)
async def welcome():
    return "<h1>Hello World!</h1>"

# Type Hint -> Runtime feature
@app.get("/users/{user_id}", response_class=HTMLResponse)
async def get_user(
    user_id: int,
    active: bool = True,
):
    return f'<h2> {user_id}, {active} </h2>'



# Request body validation with Pydantic
"""
curl -X POST "http://127.0.0.1:8000/users" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "Daniel",
    "age": 20,
    "email": "abc@example.com"
  }' | jq

  curl -X POST "http://127.0.0.1:8000/users" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "Jaden",
    "age": "hello",
    "email": "abc@example.com"
  }' | jq

  1. CreateUserRequest 
  2. Request Body로 해석 
  3. JSON parsing
  4. Pydantic validation
  5. 실패 시 HTTP validation error 반환
  6. 성공하면 Python object로 endpoint에 전달
  """
@app.post("/users")
async def create_user(
    request: CreateUserRequest
):
    return request


"""
@app.get("/users/{user_id}")
async def get_user(
    user_id: int,
    limit: int = 10,
    user: User = Depends(get_current_user),
) -> UserResponse:
    ...


user_id
→ Path Parameter
→ int validation

limit
→ Query Parameter
→ int
→ default = 10

user
→ Dependency Injection

return
→ UserResponse

전체
→ OpenAPI Schema
"""


##############

def create_db_connection():
    print("create_db_connection")
    return "db_conn"

def get_token():
    print("get_token")
    return "token"

def verify_token(token):
    print("verify_token")
    print(token)
    return "me"

@app.get("/users", response_class=HTMLResponse)
async def get_users():
    db = create_db_connection()

    token = get_token()
    user = verify_token(token)

    if user:
        return f'<h2> USERS from {db} -> {user} </h2>'

@app.post("/orders")
async def create_order():
    db = create_db_connection()

    token = get_token()
    user = verify_token(token)
    return


from fastapi import Depends


def get_current_user():
    token = get_token()
    user = verify_token(token)
    return user


@app.get("/getme", response_class=HTMLResponse)
async def get_me(
    user = Depends(get_current_user)
):
    return f'<h2> ME: {user} </h2>'


async def get_token_async():
    return "token"

async def get_curr_user(
        token = Depends(get_token_async)
):
    return "user " + token

async def get_admin(
        user = Depends(get_curr_user)
):
    return "admin " + user

@app.get("/getadmin", response_class=HTMLResponse)
async def getadmin(
    admin = Depends(get_admin)
):
    return f'<h2> ADMIN: {admin} </h2>'
