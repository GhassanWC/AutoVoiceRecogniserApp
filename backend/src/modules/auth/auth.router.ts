import { Router } from 'express';
import { z } from 'zod';
import { createGuest, login, register } from './auth.service';

export const authRouter = Router();

const guestSchema = z.object({
  preferredLanguage: z.string().min(2).max(8).optional(),
});

const registerSchema = z.object({
  email: z.string().email(),
  password: z.string().min(8).max(200),
  name: z.string().min(1).max(100).optional(),
});

const loginSchema = z.object({
  email: z.string().email(),
  password: z.string().min(1).max(200),
});

authRouter.post('/guest', async (req, res, next) => {
  try {
    const body = guestSchema.parse(req.body ?? {});
    res.json(await createGuest(body.preferredLanguage));
  } catch (error) {
    next(error);
  }
});

authRouter.post('/register', async (req, res, next) => {
  try {
    const body = registerSchema.parse(req.body);
    res.json(await register(body.email, body.password, body.name));
  } catch (error) {
    next(error);
  }
});

authRouter.post('/login', async (req, res, next) => {
  try {
    const body = loginSchema.parse(req.body);
    res.json(await login(body.email, body.password));
  } catch (error) {
    next(error);
  }
});
